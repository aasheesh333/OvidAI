/// Client side of the Ovid Cloud multiplexed WebSocket (P8 Task 6).
///
/// One socket carries subscriptions to ALL sessions (the gateway's
/// `/cloud/ws` route, cloud/apps/gateway/src/routes/wsRoute.ts). Every wire
/// shape here mirrors the BUILT `@ovid/shared` `ws.ts`/`events.ts` — the
/// server is the contract:
///
/// - client → server: `{"op":"subscribe","sessionId":…,"lastEventId":…}`,
///   `{"op":"unsubscribe","sessionId":…}`, `{"op":"ping"}` (the `pty_*` and
///   `browser_*` ops of Tasks 15/16 are additive discriminants — they go
///   through [WsMultiplexer.sendRaw] / [WsMultiplexer.rawServerFrames]);
/// - server → client: `subscribed` (additively `{trimmed:true}` when the
///   replay hit the server's REPLAY_LIMIT — the backlog may extend past it,
///   the durable gap signal that triggers the DB-mirror fallback) /
///   `event{event:SessionEvent}` / `pong` / `error{code,message,sessionId?,
///   ptyId?}`;
/// - close code 4401 (`WS_CLOSE_UNAUTHENTICATED`) = the single-use ticket
///   was missing/invalid/reused → re-mint + reconnect, silently.
///
/// Cert pinning comes free: the production socket is dart:io's
/// `WebSocket.connect`, which builds its handshake through
/// `HttpOverrides.global` — `OvidPinningHttpOverrides`
/// (lib/core/cert_pinning.dart:129) hooks every `HttpClient`, so the WS
/// handshake is pinned exactly like REST. Pinned by test (m).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, WebSocket;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_config.dart';
import 'cloud_rest.dart';
import '../connection_service.dart';

/// SharedPreferences key prefix holding the per-session replay cursor
/// (`max seq` seen): `ovid_cloud_last_event_<sessionId>`.
const String _lastEventKey = 'ovid_cloud_last_event_';

/// App-private close code for a failed ticket handshake
/// (`WS_CLOSE_UNAUTHENTICATED`, cloud/apps/gateway/src/ws.ts).
const int _closeUnauthenticated = 4401;

/// Close code this client uses when a heartbeat pong times out (any
/// non-4401 close follows the normal reconnect backoff).
const int _closePongTimeout = 4000;

/// Frames buffered while a connect is in flight, mirroring the server's
/// pre-auth queue cap (`PRE_AUTH_QUEUE_MAX` in the gateway ws.ts): beyond
/// this, outbound frames are dropped (logged) rather than buffered.
const int _outboundQueueMax = 32;

// ---------------------------------------------------------------------------
// CloudSessionEvent — the BUILT SessionEvent shape (shared/src/events.ts)
// ---------------------------------------------------------------------------

/// One session event off the wire. Named `CloudSessionEvent` to keep the
/// wire event distinct from transcript/UI event types.
class CloudSessionEvent {
  const CloudSessionEvent({
    required this.sessionId,
    required this.seq,
    required this.type,
    required this.payload,
    required this.ts,
  });

  factory CloudSessionEvent.fromJson(Map<String, dynamic> j) =>
      CloudSessionEvent(
        sessionId: j['sessionId'] as String,
        seq: j['seq'] as String,
        type: j['type'] as String,
        payload: j['payload'] is Map
            ? Map<String, dynamic>.from(j['payload'] as Map)
            : const <String, dynamic>{},
        ts: DateTime.parse(j['ts'] as String),
      );

  final String sessionId;

  /// Redis stream id `"<ms>-<idx>"` — compare with
  /// [WsMultiplexer.compareSeq], never lexicographically.
  final String seq;

  final String type;
  final Map<String, dynamic> payload;
  final DateTime ts;
}

/// A server `{"op":"error"}` frame surfaced on a session's stream. The
/// multiplexer only forwards (never rethrows) these.
class CloudWsError {
  const CloudWsError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'CloudWsError: $code: $message';
}

// ---------------------------------------------------------------------------
// CloudSocket — the dart:io WebSocket test seam
// ---------------------------------------------------------------------------

/// Test seam over `dart:io` [WebSocket]. `frames` carries every inbound
/// frame (text frames as decoded [String]s; binary frames — the P6 browser
/// channel — pass through undecoded for Task 16 to handle).
abstract class CloudSocket {
  Stream<Object> get frames;

  void sendText(String frame);

  Future<void> close([int? code, String? reason]);

  /// Fires exactly once when the socket closes (either side).
  Stream<void> get closed;

  /// The close code once available (null while open / absent on the wire).
  int? get closeCode;
}

typedef CloudSocketFactory = Future<CloudSocket> Function(Uri url);

/// The production factory: dart:io's `WebSocket.connect`. The handshake
/// client is built through `HttpClient()` AT CALL TIME — the factory
/// consults `HttpOverrides.current`, so `OvidPinningHttpOverrides`
/// (installed at boot) pins the WS origin exactly like REST. Passing it as
/// `customClient` matters: the SDK's fallback is a `static final
/// HttpClient` initialized on FIRST use process-wide, whose pinning would
/// depend on static-init order rather than on the boot-time install.
/// Pinned by test (m).
Future<CloudSocket> defaultCloudSocketFactory(Uri url) async {
  final client = HttpClient(); // consults HttpOverrides → pinning applies
  try {
    return _IoCloudSocket(
        await WebSocket.connect(url.toString(), customClient: client));
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
}

class _IoCloudSocket implements CloudSocket {
  _IoCloudSocket(this._ws) {
    _ws.done.whenComplete(() {
      _closeCode = _ws.closeCode;
      if (!_closed.isClosed) {
        _closed.add(null);
        // Single-fire stream: close right after the one event.
        _closed.close();
      }
    });
  }

  final WebSocket _ws;
  final StreamController<void> _closed = StreamController<void>();
  int? _closeCode;

  @override
  Stream<Object> get frames => _ws.map<Object>((dynamic frame) => frame);

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) => _ws.add(frame);

  @override
  Future<void> close([int? code, String? reason]) async {
    _ws.close(code, reason);
    await _ws.done;
  }
}

// ---------------------------------------------------------------------------
// The multiplexer
// ---------------------------------------------------------------------------

enum WsLinkState { disconnected, connecting, online }

/// Reads the DB `session_event_mirror` catch-up (P1's durable ledger copy —
/// `eventMirror.readSince` in @ovid/db) for the replay fallback: events with
/// seq strictly AFTER `lastSeq` (null ⇒ from the beginning), in seq order.
typedef CloudMirrorReader = Future<List<CloudSessionEvent>> Function(
  String sessionId,
  String? lastSeq,
);

/// One session subscription's client-side state.
class _SessionSub {
  _SessionSub(this.sessionId, {void Function()? onCancel})
      : events = StreamController<CloudSessionEvent>(onCancel: onCancel);

  final String sessionId;

  /// The session's stream — CACHED so [WsMultiplexer.subscribe] returns the
  /// same instance for repeat calls (`StreamController.stream` wraps a new
  /// controller-stream object on every access).
  late final Stream<CloudSessionEvent> stream = events.stream;

  /// Emits each accepted event exactly once (per-seq dedupe upstream).
  ///
  /// `onCancel` drops the registration: without it, a cancelled listener left
  /// the multiplexer holding a subscription nobody reads, so it kept the
  /// socket alive and retried forever after the screen that wanted it closed.
  final StreamController<CloudSessionEvent> events;

  /// Replay cursor: the max seq accepted for this session. Seeded from
  /// SharedPreferences at registration, updated on every accepted event.
  String? lastEventId;

  /// True while the DB-mirror catch-up is in flight for this session.
  bool mirrorInFlight = false;
}

/// One multiplexed connection to `/cloud/ws`: ticket lifecycle, per-session
/// subscribe/unsubscribe with seq dedupe, lastEventId persistence,
/// reconnect backoff, heartbeat, and the DB-mirror replay fallback.
///
///     final ws = WsMultiplexer.I;
///     ws.subscribe(sessionId).listen(foldIntoTranscript);
///
/// The gateway is the wire contract (cloud/apps/gateway/src/ws.ts):
/// every (re)connect mints a FRESH single-use ticket (60 s TTL) into the
/// query string; a 4401 close re-mints and reconnects silently.
class WsMultiplexer extends ChangeNotifier {
  WsMultiplexer({
    required this._mintTicket,
    CloudSocketFactory? socketFactory,
    this._prefs,
    this._connection,
    this.heartbeatInterval = const Duration(seconds: 25),
    this.pongTimeout = const Duration(seconds: 10),
    CloudMirrorReader? mirrorReader,
    this._jitterMs,
    String? wsUrl,
  })  : _factory = socketFactory ?? defaultCloudSocketFactory,
        _mirrorReader = mirrorReader ?? _restMirrorReader,
        _wsBase = wsUrl ?? CloudConfig.wsUrl {
    _connection?.addListener(_onConnectionChanged);
  }

  static WsMultiplexer? _instance;

  /// The process-wide default (production wiring: `CloudRestClient.I`).
  static WsMultiplexer get I =>
      _instance ??= WsMultiplexer(mintTicket: CloudRestClient.I.mintTicket);

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(WsMultiplexer ws) => _instance = ws;

  final Future<String> Function() _mintTicket;
  final CloudSocketFactory _factory;
  final ConnectionService? _connection;
  final CloudMirrorReader _mirrorReader;
  final String _wsBase;

  /// Heartbeat: `{"op":"ping"}` every [heartbeatInterval]; a pong missing
  /// within [pongTimeout] closes the socket and reconnects.
  final Duration heartbeatInterval;
  final Duration pongTimeout;

  /// Reconnect jitter in ms (0–250) — the `jitterMs` constructor parameter,
  /// injectable for deterministic tests.
  final int Function()? _jitterMs;

  SharedPreferences? _prefs;
  final Random _random = Random();

  WsLinkState _linkState = WsLinkState.disconnected;
  CloudSocket? _socket;
  StreamSubscription<Object>? _framesSub;
  StreamSubscription<void>? _closedSub;
  Future<void>? _connectFuture;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _pongTimer;
  bool _userDisconnecting = false;

  /// Whether anything wants the link up (a subscribe/sendRaw/connect call,
  /// and not a user disconnect since). Drives the offline→online retry.
  bool _wantLink = false;

  /// Connect-generation counter: bumped on every NEW connect chain AND on
  /// teardown (disconnect/dispose). An in-flight connect is valid only while
  /// its own generation is current — this is what kills the
  /// disconnect-vs-in-flight-connect race (a connect that was minting or
  /// handshaking when the user tore the link down must never attach).
  int _generation = 0;

  /// Consecutive failed connect cycles; reset by a `pong`/`subscribed`.
  int _attempt = 1;

  /// Outbound frames buffered while a connect is in flight.
  final List<Map<String, Object?>> _outboundQueue = <Map<String, Object?>>[];

  final Map<String, _SessionSub> _subs = <String, _SessionSub>{};

  /// Cursors seeded by Task 9's offline cache BEFORE [subscribe]. Kept
  /// in-memory so [subscribe] can consult it synchronously (the pref write
  /// is async); once a subscription exists, its `lastEventId` wins.
  final Map<String, String?> _seededCursors = <String, String?>{};

  /// Decoded server frames NOT consumed by the session-event pipeline
  /// (`pty_*`, `browser_state`, future additive ops) — the Tasks 15/16
  /// channel seam. Broadcast: attach before the frames you care about.
  final StreamController<Map<String, dynamic>> _rawFrames =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Current link state; [notifyListeners] fires on every transition.
  WsLinkState get linkState => _linkState;

  /// Server frames outside the session-event pipeline (see [_rawFrames]).
  Stream<Map<String, dynamic>> get rawServerFrames => _rawFrames.stream;

  /// Every ACCEPTED (seq-deduped) session event of every subscribed session,
  /// for read-only observers that are not the session's owner — Studio
  /// refreshes the shared workspace on agent file events (ST-006). The
  /// per-session [subscribe] streams are single-subscription and stay owned
  /// by the facade. Broadcast: attach before the events you care about.
  final StreamController<CloudSessionEvent> _sessionEvents =
      StreamController<CloudSessionEvent>.broadcast();

  /// See [_sessionEvents].
  Stream<CloudSessionEvent> get sessionEvents => _sessionEvents.stream;

  /// Raw BINARY server frames — the P6 browser screencast (Task 16). The
  /// gateway sends image bytes only (it strips redis's 1-byte format prefix);
  /// the image format travels in the latest `browser_state`. Broadcast:
  /// attach before the frames you care about.
  final StreamController<Uint8List> _binaryFrames =
      StreamController<Uint8List>.broadcast();

  /// Raw binary frames (see [_binaryFrames]).
  Stream<Uint8List> get binaryServerFrames => _binaryFrames.stream;

  /// Sessions whose RAW-lane consumer (the P6 browser attach) must also see
  /// session-scoped `error` frames. Those errors normally surface only on
  /// the session-event stream ([_onErrorFrame]); the browser channel has no
  /// session subscription and would otherwise never observe
  /// `forbidden`/`unavailable`/`internal`/`not_attached`.
  final Set<String> _rawSessionErrorWatchers = <String>{};

  /// Registers [sessionId] for raw-lane session error frames (idempotent).
  void watchSessionErrors(String sessionId) =>
      _rawSessionErrorWatchers.add(sessionId);

  /// Stops forwarding [sessionId]'s errors to the raw lane (idempotent).
  void unwatchSessionErrors(String sessionId) =>
      _rawSessionErrorWatchers.remove(sessionId);

  /// The replay cursor currently held for [sessionId]: the live
  /// subscription's max accepted seq, else a Task 9 seed, else the persisted
  /// pref. Task 9 records it as the offline cache's high-water mark.
  Future<String?> cursorFor(String sessionId) async {
    final sub = _subs[sessionId];
    if (sub?.lastEventId != null) return sub!.lastEventId;
    if (_seededCursors.containsKey(sessionId)) {
      return _seededCursors[sessionId];
    }
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      return prefs.getString('$_lastEventKey$sessionId');
    } catch (_) {
      return null;
    }
  }

  /// Aligns the replay cursor for [sessionId] BEFORE [subscribe] (P8 Task 9,
  /// the T7 cursor carry): the offline cache's high-water mark is the seq up
  /// to which the seeded transcript is authoritative, so the server must
  /// replay everything AFTER it and the projector must drop everything at or
  /// below it. Idempotent; a later [subscribe] uses the seeded value. When a
  /// subscription already exists, its next reconnect re-subscribes from
  /// [seq] (the current socket is not interrupted).
  void seedCursor(String sessionId, String? seq) {
    // CH-015: a cache seed never moves a cursor BACKWARDS — an older cache
    // high-water mark would replay (and duplicate) everything since it.
    final current = _subs[sessionId]?.lastEventId ??
        (_seededCursors.containsKey(sessionId)
            ? _seededCursors[sessionId]
            : _prefs?.getString('$_lastEventKey$sessionId'));
    if (current != null && (seq == null || compareSeq(seq, current) < 0)) {
      return;
    }
    _seededCursors[sessionId] = seq;
    _subs[sessionId]?.lastEventId = seq;
    unawaited(_persistSeededCursor(sessionId, seq));
  }

  /// Wave 1b (CH-003): REBASES the replay cursor onto a fresh REST snapshot's
  /// watermark — backwards too, because the projection was just rebuilt AT
  /// that watermark — and, when the session is live, re-subscribes from it
  /// so every event after the snapshot (including ones this socket already
  /// delivered during the page request) replays into the rebuilt fold. The
  /// gateway replaces a re-subscribe in place.
  void rebaseCursor(String sessionId, String? seq) {
    _seededCursors[sessionId] = seq;
    _pendingCursors.remove(sessionId);
    unawaited(_persistSeededCursor(sessionId, seq));
    final sub = _subs[sessionId];
    if (sub == null) return;
    sub.lastEventId = seq;
    if (_linkState == WsLinkState.online && _socket != null) {
      _send(_subscribeFrame(sessionId, seq));
    }
  }

  // -------------------------------------------------------------------------
  // Public surface
  // -------------------------------------------------------------------------

  /// Idempotent: registers the session and (connecting first if needed)
  /// sends `{"op":"subscribe","sessionId":…,"lastEventId":<persisted or
  /// null>}`. The returned stream emits each event for the session EXACTLY
  /// once — duplicates by seq are dropped (same-seq and below-cursor
  /// arrivals alike). Server `error` frames naming this session surface on
  /// the stream as [CloudWsError] errors (except the ones the mirror
  /// fallback heals).
  Stream<CloudSessionEvent> subscribe(String sessionId) {
    final existing = _subs[sessionId];
    if (existing != null) return existing.stream;

    final sub = _SessionSub(
      sessionId,
      onCancel: () => unsubscribe(sessionId),
    );
    sub.lastEventId = _seededCursors.containsKey(sessionId)
        ? _seededCursors[sessionId]
        : _prefs?.getString('$_lastEventKey$sessionId');
    _subs[sessionId] = sub;

    if (_linkState == WsLinkState.online && _socket != null) {
      _send(_subscribeFrame(sessionId, sub.lastEventId));
    } else {
      unawaited(connectIfNeeded());
    }
    return sub.stream;
  }

  /// Stops the subscription: sends `{"op":"unsubscribe","sessionId":…}`
  /// (when online), completes the stream, keeps the persisted cursor so a
  /// later [subscribe] replays from where this one stopped.
  void unsubscribe(String sessionId) {
    final sub = _subs.remove(sessionId);
    if (sub == null) return; // idempotent
    // CH-014: a later re-subscribe must resume from THIS subscription's
    // high-water mark — never from an older seed (which would replay, and
    // duplicate, everything since).
    final last = sub.lastEventId;
    if (last != null) _seededCursors[sessionId] = last;
    flushPendingCursors();
    if (_linkState == WsLinkState.online && _socket != null) {
      _send(<String, Object?>{'op': 'unsubscribe', 'sessionId': sessionId});
    }
    unawaited(sub.events.close().catchError((Object _) {}));
    // Nothing is listening any more: stop retrying a socket nobody reads.
    // Without this a cancelled subscription left the reconnect timer armed,
    // so a closed screen kept dialling the gateway (and a widget test ended
    // with a pending timer).
    if (_subs.isEmpty) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
  }

  /// Connects if the link is not already up/coming up. A no-op while
  /// [ConnectionService] reports offline (the flip to online retries).
  Future<void> connectIfNeeded() async {
    _wantLink = true;
    if (_linkState == WsLinkState.online || _linkState == WsLinkState.connecting) {
      final pending = _connectFuture;
      if (pending != null) await pending;
      return;
    }
    if (_isOffline) return; // _onConnectionChanged retries on the flip
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _connect();
  }

  /// User-initiated teardown (app detached). Cancels every timer, closes
  /// the socket, schedules NO reconnect. Subscriptions stay REGISTERED
  /// (their streams stay open) so a later [connectIfNeeded] re-subscribes
  /// them from their persisted cursors.
  Future<void> disconnect() async {
    _userDisconnecting = true;
    _wantLink = false;
    flushPendingCursors();
    // Invalidate any in-flight connect chain (mint/handshake in progress):
    // its generation is now stale, so its next checkpoint aborts — and a
    // later connectIfNeeded() starts a FRESH chain instead of awaiting the
    // doomed one.
    _generation++;
    _connectFuture = null;
    _attempt = 1;
    _cancelHeartbeat();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    _detachSocketListeners();
    if (_linkState != WsLinkState.disconnected) {
      _linkState = WsLinkState.disconnected;
      notifyListeners();
    }
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {
        // Already dead — the reconnect machinery is not involved here.
      }
    }
    _userDisconnecting = false;
  }

  /// Account switch / sign-out (SH-008): the socket's ticket was minted for
  /// the previous uid and the gateway rejects that socket's subscribes for
  /// any other account, so tear the link down AND forget every
  /// subscription and replay cursor (they name the previous account's
  /// sessions). The next [connectIfNeeded] mints a fresh ticket for the
  /// current account.
  Future<void> resetForAccountChange() async {
    await disconnect();
    for (final sub in _subs.values) {
      unawaited(sub.events.close().catchError((Object _) {}));
    }
    _subs.clear();
    _seededCursors.clear();
    _rawSessionErrorWatchers.clear();
    _outboundQueue.clear();
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(_lastEventKey)) await prefs.remove(key);
      }
    } catch (err) {
      debugPrint('cloud ws: cursor reset failed: $err');
    }
  }

  /// Active session subscriptions (diagnostics/tests).
  @visibleForTesting
  int get subscriptionCountForTest => _subs.length;

  /// Sends an arbitrary op frame over the multiplexed socket (the Tasks
  /// 15/16 `pty_*`/`browser_*` lane), connecting first if needed. Frames
  /// sent mid-connect are buffered (≤ [_outboundQueueMax]) and flushed once
  /// the socket opens — the gateway queues pre-auth frames the same way.
  Future<void> sendRaw(Map<String, Object?> frame) async {
    _wantLink = true;
    if (_linkState != WsLinkState.online) {
      await connectIfNeeded();
    }
    _send(frame);
  }

  /// Redis stream ids are `"<ms>-<idx>"`. Compare NUMERICALLY on both
  /// parts — a lexicographic compare breaks the moment the millisecond
  /// part changes width ("10-0" vs "9-99"). Missing parts count as 0.
  /// Mirrors `compareSeq` in the gateway's ws.ts.
  @visibleForTesting
  static int compareSeq(String a, String b) {
    final ap = _seqParts(a);
    final bp = _seqParts(b);
    if (ap.$1 != bp.$1) return ap.$1 < bp.$1 ? -1 : 1;
    if (ap.$2 != bp.$2) return ap.$2 < bp.$2 ? -1 : 1;
    return 0;
  }

  static (int, int) _seqParts(String seq) {
    final dash = seq.indexOf('-');
    final ms = int.tryParse(dash == -1 ? seq : seq.substring(0, dash)) ?? 0;
    final idx =
        int.tryParse(dash == -1 ? '0' : seq.substring(dash + 1)) ?? 0;
    return (ms, idx);
  }

  @override
  void dispose() {
    _wantLink = false;
    flushPendingCursors();
    _generation++; // invalidate any in-flight connect chain
    _connectFuture = null;
    // Hygiene: a disposed link is down. Without this, a sync dispose inside
    // the connecting-transition notifyListeners leaves linkState stuck at
    // `connecting`, and connectIfNeeded's already-connecting branch would
    // silently no-op — the same silent link death the identity guard in
    // _connect() closes. (No notifyListeners: the notifier is being torn
    // down; a later connect attempt surfaces the framework's own
    // used-after-disposed error instead.)
    _linkState = WsLinkState.disconnected;
    _cancelHeartbeat();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _detachSocketListeners();
    _socket = null;
    _connection?.removeListener(_onConnectionChanged);
    for (final sub in _subs.values) {
      unawaited(sub.events.close().catchError((Object _) {}));
    }
    _subs.clear();
    unawaited(_rawFrames.close().catchError((Object _) {}));
    unawaited(_binaryFrames.close().catchError((Object _) {}));
    unawaited(_sessionEvents.close().catchError((Object _) {}));
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Connect / reconnect lifecycle
  // -------------------------------------------------------------------------

  bool get _isOffline =>
      _connection?.status == ConnectionStatus.offline;

  /// True when the user tore the link down (or a newer connect chain
  /// superseded this one) while [generation] was in flight.
  bool _isTornDown(int generation) => !_wantLink || generation != _generation;

  Future<void> _connect() {
    final pending = _connectFuture;
    if (pending != null) return pending;
    final generation = ++_generation;
    // `late final` so the identity guard below can close over `future`
    // (the whenComplete callback always runs on a later microtask, after
    // the assignment).
    late final Future<void> future;
    future = _connectInner(generation).whenComplete(() {
      // Identity-based clear: only THIS chain's own future may vacate the
      // slot. A newer chain's future is protected (never clobbered by a
      // stale completion), and a chain torn down synchronously INSIDE the
      // connecting-transition notifyListeners — before the slot assignment
      // below — self-heals the slot instead of leaving its dead future
      // there to short-circuit every later _connect() (silent link death).
      if (_connectFuture == future) _connectFuture = null;
    });
    _connectFuture = future;
    return future;
  }

  Future<void> _connectInner(int generation) async {
    // The offline gate may have flipped between scheduling and firing.
    if (_isOffline) return;

    _linkState = WsLinkState.connecting;
    notifyListeners();

    // EVERY (re)connect mints a FRESH single-use ticket (60 s TTL).
    String ticket;
    try {
      ticket = await _mintTicket();
    } catch (err) {
      debugPrint('cloud ws: ticket mint failed: $err');
      _onConnectFailure(generation);
      return;
    }
    // disconnect() may have raced the mint — nothing exists yet to clean up.
    if (_isTornDown(generation)) return;

    CloudSocket socket;
    try {
      socket = await _factory(
        Uri.parse('$_wsBase?ticket=${Uri.encodeQueryComponent(ticket)}'),
      );
    } catch (err) {
      debugPrint('cloud ws: connect failed: $err');
      _onConnectFailure(generation);
      return;
    }
    // disconnect() raced the handshake: close the stray socket instead of
    // attaching it (an attached stray would re-subscribe sessions and later
    // trigger reconnection forever after user teardown).
    if (_isTornDown(generation)) {
      _closeQuietly(socket);
      return;
    }

    _attach(socket, generation);
  }

  void _onConnectFailure(int generation) {
    // A torn-down chain must not touch link state or schedule reconnects —
    // a newer chain may legitimately be connecting.
    if (_isTornDown(generation)) return;
    _linkState = WsLinkState.disconnected;
    notifyListeners();
    _scheduleReconnect();
  }

  void _attach(CloudSocket socket, int generation) {
    // Defense in depth for the teardown race (checks already ran after the
    // factory await, but nothing may attach once the link is unwanted).
    if (_isTornDown(generation)) {
      _closeQuietly(socket);
      return;
    }
    _socket = socket;
    _framesSub = socket.frames.listen(
      _onFrame,
      onError: (Object err) => debugPrint('cloud ws: socket error: $err'),
    );
    _closedSub = socket.closed.listen((_) => _onSocketClosed(socket));
    _linkState = WsLinkState.online;
    notifyListeners();

    // Re-subscribe every active session with its persisted cursor FIRST
    // (the gateway's ownership check + subscription cap run per subscribe),
    // then flush any frames buffered mid-connect.
    for (final sub in _subs.values) {
      sub.lastEventId ??= _seededCursors[sub.sessionId] ??
          _prefs?.getString('$_lastEventKey${sub.sessionId}');
      _send(_subscribeFrame(sub.sessionId, sub.lastEventId));
    }
    final queued = List<Map<String, Object?>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final frame in queued) {
      _send(frame);
    }

    _startHeartbeat();
  }

  void _onSocketClosed(CloudSocket socket) {
    if (_socket != socket) return; // stale listener from a replaced socket
    _cancelHeartbeat();
    _detachSocketListeners();
    final closeCode = socket.closeCode;
    _socket = null;
    _linkState = WsLinkState.disconnected;
    notifyListeners();

    // Teardown owns what happens next (explicit disconnect, or the user
    // tore the link down while this close was in flight) — never schedule.
    if (_userDisconnecting || !_wantLink) return;
    if (_isOffline) return; // flip to online retries (_onConnectionChanged)

    // 4401 = ticket rejected → re-mint + reconnect silently (Review Focus
    // #1). The first consecutive 4401 heals immediately (the common case is
    // a mint/connect race); repeats back off like any other failure so a
    // persistently rejecting server cannot spin the client.
    _scheduleReconnect(immediate: closeCode == _closeUnauthenticated);
  }

  /// `min(60s, 1s * 2^(attempt-1))` + 0–250 ms jitter. [immediate] (4401 on
  /// the first consecutive attempt) skips the delay entirely.
  void _scheduleReconnect({bool immediate = false}) {
    if (_userDisconnecting) return;
    // No intent to hold a link: do not arm a timer that would only discover
    // that on its own callback. This is what left a pending timer after a
    // torn-down screen (and a failing widget-test teardown).
    if (!_wantLink) return;
    if (_isOffline) return; // flip to online retries (_onConnectionChanged)

    final delay =
        immediate && _attempt == 1 ? Duration.zero : _backoffDelay(_attempt);
    _attempt++;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      // Defense in depth: if teardown happened without the timer being
      // canceled, never reconnect on a dead intent.
      if (!_wantLink) return;
      unawaited(_connect());
    });
  }

  Duration _backoffDelay(int attempt) {
    // exp capped at 16: 1<<16 s = 18h, far past the 60s cap — avoids int
    // overflow on pathological attempt counts.
    final exp = min(attempt - 1, 16);
    var seconds = 1 << exp;
    const cap = 60;
    if (seconds > cap) seconds = cap;
    final jitterMs = _jitterMs?.call() ?? _random.nextInt(251);
    return Duration(seconds: seconds, milliseconds: jitterMs);
  }

  void _onConnectionChanged() {
    final connection = _connection;
    if (connection == null) return;
    if (connection.status != ConnectionStatus.online) return;
    // The offline gate blocked a connect/reconnect — retry now that we are
    // back online (only when something still wants the link).
    if (!_wantLink) return;
    if (_linkState != WsLinkState.disconnected) return;
    if (_reconnectTimer != null) return; // a reconnect is already scheduled
    unawaited(connectIfNeeded());
  }

  // -------------------------------------------------------------------------
  // Heartbeat
  // -------------------------------------------------------------------------

  void _startHeartbeat() {
    _cancelHeartbeat();
    _pingTimer = Timer.periodic(heartbeatInterval, (_) {
      _send(<String, Object?>{'op': 'ping'});
      _pongTimer?.cancel();
      _pongTimer = Timer(pongTimeout, () {
        // No pong in time: the link is dead — close and let the normal
        // reconnect machinery take over.
        final socket = _socket;
        if (socket == null) return;
        unawaited(socket.close(_closePongTimeout, 'pong timeout'));
      });
    });
  }

  void _cancelHeartbeat() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
  }

  /// Closes a socket whose connect chain was invalidated (teardown race) —
  /// best-effort, never throws, never reconnects.
  void _closeQuietly(CloudSocket socket) {
    try {
      unawaited(socket.close().catchError((Object _) {}));
    } catch (_) {
      // Synchronous close failure — the socket is already dead.
    }
  }

  void _detachSocketListeners() {
    _framesSub?.cancel();
    _framesSub = null;
    _closedSub?.cancel();
    _closedSub = null;
  }

  // -------------------------------------------------------------------------
  // Frame plumbing
  // -------------------------------------------------------------------------

  Map<String, Object?> _subscribeFrame(String sessionId, String? lastEventId) =>
      <String, Object?>{
        'op': 'subscribe',
        'sessionId': sessionId,
        'lastEventId': lastEventId,
      };

  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket != null && _linkState == WsLinkState.online) {
      socket.sendText(jsonEncode(frame));
      return;
    }
    // Mid-connect: buffer and flush on open (the gateway queues pre-auth
    // frames the same way, capped at PRE_AUTH_QUEUE_MAX).
    if (_outboundQueue.length >= _outboundQueueMax) {
      debugPrint('cloud ws: outbound queue full, dropping frame: $frame');
      return;
    }
    _outboundQueue.add(frame);
  }

  void _onFrame(Object frame) {
    if (frame is! String) {
      // Binary frames are the P6 browser screencast (Task 16), not part of
      // the session-event pipeline. `dart:io` delivers them as Uint8List;
      // accept a plain byte list too so a fake socket can emit either.
      if (frame is Uint8List) {
        if (!_binaryFrames.isClosed) _binaryFrames.add(frame);
      } else if (frame is List<int>) {
        if (!_binaryFrames.isClosed) {
          _binaryFrames.add(Uint8List.fromList(frame));
        }
      }
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (err) {
      debugPrint('cloud ws: unparseable frame dropped: $err');
      return;
    }
    if (decoded is! Map) return;
    final msg = Map<String, dynamic>.from(decoded);

    switch (msg['op']) {
      case 'event':
        final raw = msg['event'];
        if (raw is! Map) return;
        CloudSessionEvent event;
        try {
          event = CloudSessionEvent.fromJson(Map<String, dynamic>.from(raw));
        } catch (err) {
          debugPrint('cloud ws: off-contract event frame dropped: $err');
          return;
        }
        final sub = _subs[event.sessionId];
        if (sub == null) return; // unsubscribed meanwhile
        _accept(sub, event);
        return;
      case 'subscribed':
        // Any subscribed ack proves the link is healthy end to end.
        _attempt = 1;
        // The additive `trimmed` flag (@ovid/shared — the DURABLE
        // replay-degradation signal, landed in the built ws.ts): the ack
        // says "exactly REPLAY_LIMIT events were replayed — the backlog
        // may extend past the cap", so the wire replay may be short of the
        // mirror's tail. Heal it through the SAME mirror catch-up the
        // legacy internal error frames trigger. The subscription stays
        // live server-side here — the catch-up's trailing re-subscribe
        // simply replaces it in place (ws.ts re-subscribe semantics), with
        // the re-seeded cursor.
        if (msg['trimmed'] == true) {
          final sessionId = msg['sessionId'];
          final sub = sessionId is String ? _subs[sessionId] : null;
          if (sub != null) {
            unawaited(
                _mirrorCatchUp(sub, 'subscribed{trimmed}: replay hit the '
                    'server cap'));
          } else {
            debugPrint('cloud ws: trimmed ack for unknown session '
                '($sessionId)');
          }
        }
        return;
      case 'pong':
        _attempt = 1; // attempt counter resets after a pong/subscribed
        _pongTimer?.cancel();
        _pongTimer = null;
        return;
      case 'error':
        _onErrorFrame(msg);
      default:
        // pty_*, browser_state, future additive ops — the Tasks 15/16 lane.
        if (!_rawFrames.isClosed) _rawFrames.add(msg);
    }
  }

  /// Dedupes by seq (at-or-below the cursor → drop), persists the new
  /// cursor, and emits on the session's stream. The single funnel for
  /// live events AND mirror-replay events — exactly-once across both.
  void _accept(_SessionSub sub, CloudSessionEvent event) {
    final cursor = sub.lastEventId;
    if (cursor != null && compareSeq(event.seq, cursor) <= 0) return;
    sub.lastEventId = event.seq;
    _persistCursorThrottled(sub.sessionId, event.seq,
        force: _terminalTypes.contains(event.type));
    sub.events.add(event);
    if (_sessionEvents.hasListener && !_sessionEvents.isClosed) {
      _sessionEvents.add(event);
    }
  }

  /// The built server's LEGACY replay-degradation signals (ws.ts): internal
  /// error frames carrying these EXACT messages, each sent after the
  /// server-side subscription was deleted ("Replay failed." — the
  /// `readSince` catch; "Live subscription failed." — the `subscribe`
  /// catch). Matched literally: other internal frames with a sessionId
  /// (the browser-attach / approval-publish failure shapes the built ws.ts
  /// also sends) are session errors, NOT replay degradation. Kept as the
  /// degraded-path detector for older servers; the DURABLE path is the
  /// additive `subscribed{trimmed}` flag consumed at `case 'subscribed'`.
  static const Set<String> _replayDegradedMessages = <String>{
    'Replay failed.',
    'Live subscription failed.',
  };

  void _onErrorFrame(Map<String, dynamic> msg) {
    final code = msg['code'];
    final message = msg['message'];
    final sessionId = msg['sessionId'];
    final codeText = code is String ? code : 'internal';
    final messageText = message is String ? message : 'Unknown error.';

    if (sessionId is String && sessionId.isNotEmpty) {
      // A browser attach (Task 16) listens on the RAW lane, not the session
      // event stream; copy the error there when one is registered. The
      // session-stream routing below is unchanged (no duplicate copy).
      if (_rawSessionErrorWatchers.contains(sessionId) &&
          !_rawFrames.isClosed) {
        _rawFrames.add(msg);
      }
      final sub = _subs[sessionId];
      if (sub == null) {
        debugPrint('cloud ws: error for unknown session '
            '($codeText: $messageText)');
        return;
      }
      if (codeText == 'internal' &&
          _replayDegradedMessages.contains(messageText)) {
        // The LEGACY degraded-path detector (older servers: ws.ts sends
        // "Replay failed." / "Live subscription failed." as internal error
        // frames and DELETES the server-side subscription). Fall back to the
        // DB event mirror for catch-up, then continue live.
        unawaited(_mirrorCatchUp(sub, messageText));
        return;
      }
      // Non-recoverable for this session (forbidden,
      // too_many_subscriptions, non-replay internal failures, …): forward,
      // never rethrow. The connection itself survives.
      sub.events.addError(CloudWsError(codeText, messageText));
      return;
    }

    // Channel-scoped error (ptyId): the Tasks 15/16 lane receives it
    // through rawServerFrames — a pty consumer must be able to surface
    // "terminal failed to open" on the seam it was given. Also logged.
    final ptyId = msg['ptyId'];
    if (ptyId is String && ptyId.isNotEmpty && !_rawFrames.isClosed) {
      _rawFrames.add(msg);
    }
    debugPrint('cloud ws: server error ($codeText: $messageText)');
  }

  // -------------------------------------------------------------------------
  // Replay fallback — the DB event mirror (P1-review deferral, owned here)
  // -------------------------------------------------------------------------

  /// The Redis stream replay is unavailable or degraded — signalled EITHER
  /// durably by the additive `subscribed{trimmed}` flag (the ack for a
  /// subscribe that replayed exactly REPLAY_LIMIT events — the backlog may
  /// extend past the server's replay cap) OR, on older servers, by an
  /// internal error frame naming the session (the replay read failed; the
  /// server DELETED the server-side subscription). Catch up from the durable
  /// `session_event_mirror` via [CloudMirrorReader], applying events
  /// through the SAME seq-dedupe, then re-subscribe live; the cursor
  /// re-seeds from the mirror's last event.
  Future<void> _mirrorCatchUp(_SessionSub sub, String why) async {
    if (sub.mirrorInFlight) return; // a catch-up is already running
    sub.mirrorInFlight = true;
    debugPrint('cloud ws: replay degraded for ${sub.sessionId} ($why) — '
        'falling back to the DB event mirror');
    try {
      final events = await _mirrorReader(sub.sessionId, sub.lastEventId);
      if (_subs[sub.sessionId] != sub) return; // unsubscribed meanwhile
      for (final event in events) {
        _accept(sub, event);
      }
      flushPendingCursors();
    } catch (err) {
      debugPrint('cloud ws: mirror catch-up failed for ${sub.sessionId}: '
          '$err');
      if (_subs[sub.sessionId] == sub && !sub.events.isClosed) {
        sub.events.addError(
            CloudWsError('internal', 'Replay degraded and mirror catch-up '
                'failed: $why'));
      }
    } finally {
      sub.mirrorInFlight = false;
    }

    // Continue live: on the legacy error-frame path the server DELETED the
    // subscription when the replay failed, so a fresh subscribe re-establishes
    // it; on the trimmed-ack path the sub is still live and the re-subscribe
    // simply replaces it in place (ws.ts re-subscribe semantics). Either way,
    // overlap with anything already delivered is dropped by the same
    // seq-dedupe in [_accept].
    if (_subs[sub.sessionId] == sub &&
        _linkState == WsLinkState.online &&
        _socket != null) {
      _send(_subscribeFrame(sub.sessionId, sub.lastEventId));
    }
  }

  /// The REST catch-up route's default page size (`DEFAULT_EVENT_LIMIT` in
  /// cloud/apps/gateway/src/routes/events.ts): a SHORT page (fewer events
  /// than this) means the mirror is exhausted — the paging loop's stop
  /// signal, exactly like a cursor-less feed.
  static const int _mirrorPageSize = 200;

  /// Bound on the mirror paging loop: 25 pages × 200 events = 5000 events —
  /// enough to heal any realistic trim gap while staying bounded. At the
  /// cap the loop gives up GRACEFULLY: accepted events stay, the cursor
  /// holds, and the next degradation signal re-triggers the fallback.
  static const int _mirrorMaxPages = 25;

  /// Default mirror reader: the gateway REST catch-up route
  /// `GET /sessions/:id/events?after=<seq>` over [CloudRestClient.I],
  /// returning `{events:[SessionEvent…]}` (the shared SessionEvent wire
  /// shape) — one 200-event page per call, so the reader pages via
  /// [readMirrorPages] rather than trusting a single page to hold the whole
  /// gap.
  static Future<List<CloudSessionEvent>> _restMirrorReader(
    String sessionId,
    String? lastSeq,
  ) {
    return readMirrorPages(
      (after) => CloudRestClient.I.getJson(
        '/sessions/$sessionId/events',
        query: <String, String>{'after': after ?? ''},
      ),
      lastSeq,
    );
  }

  /// Pages a mirror catch-up until the mirror is exhausted: each fetch asks
  /// for events strictly AFTER the last seq of the previous page (the route's
  /// `after` is the exclusive resume cursor); a SHORT page — fewer than
  /// [_mirrorPageSize] events, the route's default limit — or an empty one
  /// means done. An off-contract response (no `events` list) ends the loop
  /// leniently, like the route's own clamp-or-ignore rule: pages already
  /// fetched are kept, never thrown away. Capped at [_mirrorMaxPages]
  /// fetches so a pathological mirror can never spin.
  @visibleForTesting
  static Future<List<CloudSessionEvent>> readMirrorPages(
    Future<Map<String, dynamic>> Function(String? after) fetchPage,
    String? lastSeq,
  ) async {
    final events = <CloudSessionEvent>[];
    var after = lastSeq;
    for (var page = 1; page <= _mirrorMaxPages; page++) {
      final json = await fetchPage(after);
      final rawEvents = json['events'];
      if (rawEvents is! List) return events; // off-contract: stop, keep pages
      final pageEvents = [
        for (final raw in rawEvents)
          if (raw is Map)
            CloudSessionEvent.fromJson(Map<String, dynamic>.from(raw)),
      ];
      events.addAll(pageEvents);
      if (pageEvents.length < _mirrorPageSize) return events;
      after = pageEvents.last.seq; // resume strictly after this page
    }
    debugPrint('cloud ws: mirror catch-up hit the $_mirrorMaxPages-page cap '
        '— giving up gracefully (the cursor holds; the next degradation '
        'signal re-triggers the fallback)');
    return events;
  }

  // -------------------------------------------------------------------------
  // Cursor persistence
  // -------------------------------------------------------------------------

  /// CH-021: at most one prefs write per session per this interval while a
  /// run streams (the in-memory cursor stays authoritative); terminal
  /// events, unsubscribe, disconnect and a finished mirror catch-up write
  /// through immediately.
  static const Duration cursorPersistInterval = Duration(seconds: 2);

  static const Set<String> _terminalTypes = <String>{
    'run_completed',
    'run_failed',
    'run_cancelled',
  };

  final Map<String, String> _pendingCursors = <String, String>{};
  final Map<String, DateTime> _lastCursorWrite = <String, DateTime>{};
  Timer? _cursorTimer;

  void _persistCursorThrottled(String sessionId, String seq,
      {bool force = false}) {
    final now = DateTime.now();
    final last = _lastCursorWrite[sessionId];
    if (force ||
        last == null ||
        now.difference(last) >= cursorPersistInterval) {
      _pendingCursors.remove(sessionId);
      _lastCursorWrite[sessionId] = now;
      _persistCursor(sessionId, seq);
      return;
    }
    _pendingCursors[sessionId] = seq;
    _cursorTimer ??= Timer(
      cursorPersistInterval - now.difference(last),
      flushPendingCursors,
    );
  }

  /// Writes every throttled cursor now (also the timer's callback).
  void flushPendingCursors() {
    _cursorTimer?.cancel();
    _cursorTimer = null;
    if (_pendingCursors.isEmpty) return;
    final now = DateTime.now();
    final pending = Map<String, String>.of(_pendingCursors);
    _pendingCursors.clear();
    for (final entry in pending.entries) {
      _lastCursorWrite[entry.key] = now;
      _persistCursor(entry.key, entry.value);
    }
  }

  void _persistCursor(String sessionId, String seq) {
    unawaited(() async {
      try {
        final prefs = _prefs ??= await SharedPreferences.getInstance();
        await prefs.setString('$_lastEventKey$sessionId', seq);
      } catch (err) {
        // Persistence is best-effort: a lost cursor only costs a re-replay
        // (the seq-dedupe keeps the transcript exactly-once regardless).
        debugPrint('cloud ws: cursor persistence failed: $err');
      }
    }());
  }

  /// Persists a Task 9 seeded cursor. Same best-effort contract as
  /// [_persistCursor]; `null` clears the pref (a cache with no events).
  Future<void> _persistSeededCursor(String sessionId, String? seq) async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      final key = '$_lastEventKey$sessionId';
      if (seq == null) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, seq);
      }
    } catch (err) {
      debugPrint('cloud ws: seeded cursor persistence failed: $err');
    }
  }
}
