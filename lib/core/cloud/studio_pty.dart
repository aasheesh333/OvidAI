import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'cloud_ws.dart';

/// Client side of the P2 terminal-over-WS channel (`cloud/packages/shared/
/// src/pty.ts`, `cloud/apps/gateway/src/wsPty.ts`).
///
/// Wire contract (built code):
///  - client → `pty_open{sessionId,cols,rows}`, `pty_attach{ptyId,lastOffset?}`,
///    `pty_input{ptyId,data(base64)}`, `pty_resize{ptyId,cols,rows}`,
///    `pty_close{ptyId}`;
///  - server → `pty_opened{ptyId,sessionId}`, `pty_attached{ptyId,truncated}`,
///    `pty_output{ptyId,data(base64),offset}`, `pty_exit{ptyId,exitCode}`,
///    `error{code,message,ptyId}`.
///
/// ## Offset reassembly (pinned correctness contract)
///
/// The attach snapshot (the ≤256 KB scrollback repaint) and live chunks can
/// be delivered OUT OF ORDER relative to each other in the post-attach window.
/// This channel therefore NEVER emits by arrival order:
///
///  1. every `pty_output` is buffered by its byte [offset];
///  2. a frame whose offset is below the highest offset already emitted is
///     discarded (it is stale/duplicate);
///  3. only contiguous bytes are emitted forward — the repaint starting at
///     offset 0 (or the lowest offset the server sends) always comes out
///     before any later-offset live bytes.
///
/// A short microtask settle window lets a live chunk that raced the snapshot
/// arrive before the first emit, so the repaint still wins.
/// ## Cross-talk prevention (one shared socket, many terminals)
///
/// Every channel listens to the SAME `WsMultiplexer.rawServerFrames` stream,
/// and the wire carries no client request id: `pty_open{sessionId,cols,rows}`
/// is answered by `pty_opened{ptyId,sessionId}` (see
/// `cloud/apps/gateway/src/ws.ts` `handlePtyOpen`). Two channels opening
/// concurrently would otherwise both adopt the first ack and share one shell.
///
/// The gateway processes frames strictly in arrival order (`ws.ts` chains
/// `processFrame`), so ack order equals request order. Channels therefore
/// share a per-multiplexer FIFO open queue: a channel ignores every pty frame
/// until it is the head of the queue and has claimed its OWN `pty_opened`, and
/// it drops any later frame whose `ptyId` is not the one it claimed. A closed
/// channel keeps its queue slot until its ack/error arrives, then releases the
/// pty, so its ack is never mis-adopted by the next tab.
class CloudPtyChannel extends ChangeNotifier {
  CloudPtyChannel({
    required this.sessionId,
    required this.tabId,
    required WsMultiplexer ws,
    int cols = 80,
    int rows = 24,
    Duration settleWindow = const Duration(milliseconds: 20),
    Stream<Map<String, dynamic>>? rawFramesOverride,
    Future<void> Function(Map<String, Object?> frame)? sendOverride,
  })  : _ws = ws,
        _cols = cols,
        _rows = rows,
        // ignore: prefer_initializing_formals
        _settleWindow = settleWindow,
        _frames = rawFramesOverride ?? ws.rawServerFrames,
        // ignore: prefer_initializing_formals
        _sendOverride = sendOverride {
    _sub = _frames.listen(
      _onFrame,
      onError: (Object error) => debugPrint('cloud pty: frame error: $error'),
    );
    _scopeFor(_ws).enqueue(sessionId, this);
    _openPending = true;
    unawaited(_send(<String, Object?>{
      'op': 'pty_open',
      'sessionId': sessionId,
      'cols': cols,
      'rows': rows,
    }));
  }

  /// Per-[WsMultiplexer] open-order registry. The queue is the only client-
  /// side correlation available on the built wire (there is no tabId/nonce).
  static final Expando<_PtyOpenScope> _scopes =
      Expando<_PtyOpenScope>('CloudPtyChannel.openScopes');

  static _PtyOpenScope _scopeFor(WsMultiplexer ws) =>
      _scopes[ws] ??= _PtyOpenScope();

  final String sessionId;
  final String tabId;
  final WsMultiplexer _ws;
  final Stream<Map<String, dynamic>> _frames;
  final Future<void> Function(Map<String, Object?> frame)? _sendOverride;
  final Duration _settleWindow;

  StreamSubscription<Map<String, dynamic>>? _sub;
  final StreamController<List<int>> _output =
      StreamController<List<int>>.broadcast();
  final StringBuffer _text = StringBuffer();

  String? _ptyId;
  int _cols;
  int _rows;
  bool _opened = false;
  bool _attached = false;
  bool _truncated = false;
  bool _closed = false;
  bool _openPending = false;
  Timer? _openTimeout;
  int? _exitCode;
  CloudWsError? _error;

  /// Latest size requested before the pty existed. `pty_open` already carried
  /// the constructor dimensions, so this is a resize to replay once the ack
  /// arrives (it must not be dropped).
  (int, int)? _pendingResize;

  /// Incomplete trailing UTF-8 sequence carried between wire chunks.
  List<int> _utf8Carry = const <int>[];

  /// Writes issued before `pty_opened` arrives are queued (the gateway needs
  /// the ptyId).
  final List<List<int>> _queuedWrites = <List<int>>[];

  /// Buffered output chunks keyed by their first byte offset.
  final Map<int, List<int>> _pending = <int, List<int>>{};

  /// First byte offset NOT yet emitted; null until the first emit.
  int? _emittedEnd;
  bool _startScheduled = false;

  /// The server's ≤256 KB scrollback, decoded for the terminal pane.
  Stream<List<int>> get output => _output.stream;

  /// Decoded scrollback text (the UI renders this).
  String get text => _text.toString();

  String? get ptyId => _ptyId;
  bool get opened => _opened;
  bool get attached => _attached;
  bool get truncated => _truncated;
  bool get closed => _closed;
  int? get exitCode => _exitCode;
  CloudWsError? get error => _error;
  int get cols => _cols;
  int get rows => _rows;

  /// Sends raw bytes to the PTY (`pty_input`, base64 on the wire).
  void write(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    final ptyId = _ptyId;
    if (ptyId == null) {
      _queuedWrites.add(List<int>.of(bytes));
      return;
    }
    _sendInput(ptyId, bytes);
  }

  /// Sends a line (adds `\n`).
  void writeln(String line) => write(utf8.encode('$line\n'));

  /// Sends Ctrl-C (0x03) — the terminal pane's Stop affordance.
  void interrupt() => write(const <int>[3]);

  void resize(int cols, int rows) {
    if (_closed) return;
    _cols = cols;
    _rows = rows;
    final ptyId = _ptyId;
    if (ptyId == null) {
      // `pty_open` was already sent in the constructor; queue the latest size
      // and replay it on `pty_opened` instead of losing it.
      _pendingResize = (cols, rows);
      return;
    }
    _sendResize(ptyId, cols, rows);
  }

  void _sendResize(String ptyId, int cols, int rows) {
    unawaited(_send(<String, Object?>{
      'op': 'pty_resize',
      'ptyId': ptyId,
      'cols': cols,
      'rows': rows,
    }));
  }

  /// Drops the local scrollback (the server's ring is untouched).
  void clearScrollback() {
    _text.clear();
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final ptyId = _ptyId;
    if (ptyId != null) {
      try {
        await _send(<String, Object?>{'op': 'pty_close', 'ptyId': ptyId});
      } catch (_) {
        // Best effort: the socket may already be gone.
      }
      await _sub?.cancel();
      _sub = null;
    } else if (!_openPending) {
      await _sub?.cancel();
      _sub = null;
    } else if (_sendOverride == null) {
      // Wait for our ack so a sibling tab cannot adopt it, but do not leak the
      // subscription (and the queue slot) forever if the socket dies. The
      // timer is skipped under the test send seam (the fake owns the ack).
      _openTimeout = Timer(const Duration(seconds: 35), () {
        _scopeFor(_ws).queueFor(sessionId).remove(this);
        unawaited(_sub?.cancel());
        _sub = null;
      });
    }
    // If the open is still in flight the subscription stays alive just long
    // enough to consume OUR ack (and close that pty). Dropping it here would
    // let the next tab adopt this channel's pty.
    if (!_output.isClosed) await _output.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Wire
  // -------------------------------------------------------------------------

  Future<void> _send(Map<String, Object?> frame) {
    final override = _sendOverride;
    return override != null ? override(frame) : _ws.sendRaw(frame);
  }

  void _sendInput(String ptyId, List<int> bytes) {
    unawaited(_send(<String, Object?>{
      'op': 'pty_input',
      'ptyId': ptyId,
      'data': base64Encode(bytes),
    }));
  }

  void _onFrame(Map<String, dynamic> frame) {
    final op = frame['op'];
    final ptyId = frame['ptyId'];

    if (op == 'pty_opened') {
      _adoptOpened(ptyId, frame['sessionId']);
      return;
    }
    if (op == 'error') {
      _onErrorFrame(frame, ptyId);
      return;
    }
    if (_closed) return;

    // A channel that has not claimed its own pty ignores EVERY other pty
    // frame. Before this guard, a second tab rendered the first tab's output.
    if (_ptyId == null || ptyId != _ptyId) return;

    switch (op) {
      case 'pty_attached':
        _attached = true;
        _truncated = frame['truncated'] == true;
        notifyListeners();
      case 'pty_output':
        final offset = (frame['offset'] as num?)?.toInt();
        final data = frame['data'];
        if (offset == null || offset < 0 || data is! String) return;
        List<int> bytes;
        try {
          bytes = base64Decode(data);
        } catch (_) {
          return; // off-contract frame: drop, never crash the channel
        }
        _onOutput(offset, bytes);
      case 'pty_exit':
        _exitCode = (frame['exitCode'] as num?)?.toInt();
        notifyListeners();
    }
  }

  /// Claims a `pty_opened` only when this channel is the oldest outstanding
  /// open for the session (the gateway acks in request order).
  void _adoptOpened(Object? ptyId, Object? frameSession) {
    if (frameSession != sessionId) return;
    if (_ptyId != null) return;
    final scope = _scopeFor(_ws);
    final queue = scope.queueFor(sessionId);
    if (ptyId is String && scope.owners.containsKey(ptyId)) {
      // The same broadcast frame reaches every channel; once one of them has
      // claimed it, the rest must not adopt it too.
      return;
    }
    if (queue.isEmpty || !identical(queue.first, this)) return;
    if (ptyId is! String || ptyId.isEmpty) {
      _failOpen('The terminal did not report an id.');
      return;
    }
    queue.removeAt(0);
    scope.owners[ptyId] = this;
    _ptyId = ptyId;
    _opened = true;
    _openPending = false;
    _openTimeout?.cancel();
    _openTimeout = null;

    final pendingResize = _pendingResize;
    _pendingResize = null;
    if (pendingResize != null) {
      _sendResize(ptyId, pendingResize.$1, pendingResize.$2);
    }

    if (_closed) {
      // The tab was closed while its open was in flight: release the pty and
      // stop listening. The ack is consumed, so no sibling tab can adopt it.
      unawaited(_send(<String, Object?>{'op': 'pty_close', 'ptyId': ptyId})
          .catchError((_) {}));
      unawaited(_sub?.cancel());
      _sub = null;
      return;
    }

    final queued = List<List<int>>.from(_queuedWrites);
    _queuedWrites.clear();
    for (final bytes in queued) {
      _sendInput(ptyId, bytes);
    }
    notifyListeners();
  }

  /// Routes an `error` frame. A bound channel only takes errors for its own
  /// pty. An unbound channel takes an open failure only when it is the head
  /// of the session's open queue (so a sibling's failure is not misreported).
  void _onErrorFrame(Map<String, dynamic> frame, Object? ptyId) {
    final scope = _scopeFor(_ws);
    final bound = _ptyId;
    if (bound != null) {
      if (ptyId is String && ptyId != bound) return;
      if (ptyId == null) {
        final frameSession = frame['sessionId'];
        if (frameSession is String && frameSession != sessionId) return;
      }
    } else {
      final queue = scope.queueFor(sessionId);
      if (queue.isEmpty || !identical(queue.first, this)) return;
      final frameSession = frame['sessionId'];
      if (frameSession is String && frameSession != sessionId) return;
      if (ptyId is String) {
        final owner = scope.owners[ptyId];
        if (owner != null && !identical(owner, this)) return;
      }
      queue.removeAt(0);
      _openPending = false;
      _openTimeout?.cancel();
      _openTimeout = null;
    }
    if (_closed) {
      if (bound == null) {
        unawaited(_sub?.cancel());
        _sub = null;
      }
      return;
    }
    _error = CloudWsError(
      (frame['code'] as String?) ?? 'internal',
      (frame['message'] as String?) ?? 'Terminal error.',
    );
    notifyListeners();
  }

  void _failOpen(String message) {
    final queue = _scopeFor(_ws).queueFor(sessionId);
    queue.remove(this);
    _openPending = false;
    _error = CloudWsError('internal', message);
    if (!_closed) notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Offset-ordered reassembly
  // -------------------------------------------------------------------------

  void _onOutput(int offset, List<int> bytes) {
    final emittedEnd = _emittedEnd;
    // Stale/duplicate: everything below the high-water mark was already sent.
    if (emittedEnd != null && offset < emittedEnd) return;
    if (_pending.containsKey(offset)) return;
    _pending[offset] = bytes;

    if (emittedEnd == null) {
      // Hold for one event-loop turn: a live chunk may have raced the
      // snapshot, and stream delivery itself is asynchronous. By the time
      // this timer fires, every already-delivered frame is buffered, so the
      // lowest offset (the repaint) is chosen first.
      if (!_startScheduled) {
        _startScheduled = true;
        Timer(_settleWindow, () {
          _startScheduled = false;
          if (_closed) return;
          _drain();
        });
      }
      return;
    }
    _drain();
  }

  void _drain() {
    if (_pending.isEmpty) return;
    if (_emittedEnd == null) {
      // The lowest offset the server sent wins — for an untruncated ring that
      // is the repaint's offset 0.
      final first = _pending.keys.reduce(math.min);
      _emitAt(first);
    }
    while (true) {
      final next = _emittedEnd;
      if (next == null) return;
      final bytes = _pending.remove(next);
      if (bytes == null) return;
      _emit(bytes, next);
    }
  }

  void _emitAt(int offset) {
    final bytes = _pending.remove(offset);
    if (bytes == null) return;
    _emit(bytes, offset);
  }

  void _emit(List<int> bytes, int offset) {
    _emittedEnd = offset + bytes.length;
    if (!_output.isClosed) _output.add(Uint8List.fromList(bytes));
    _appendText(bytes);
    notifyListeners();
  }

  void _appendText(List<int> bytes) {
    // The wire splits chunks at PTY_WIRE_MAX_BYTES (16 KiB) on arbitrary byte
    // boundaries, so a multi-byte UTF-8 character can straddle two chunks.
    // Decoding each chunk independently renders U+FFFD for both halves; carry
    // the incomplete tail and prepend it to the next chunk instead.
    final all = _utf8Carry.isEmpty
        ? bytes
        : <int>[..._utf8Carry, ...bytes];
    var cut = all.length;
    // A trailing sequence is incomplete when its lead byte is within the last
    // four bytes and fewer than `need` bytes remain.
    for (var i = all.length - 1; i >= 0 && i >= all.length - 4; i--) {
      final b = all[i];
      if ((b & 0xC0) == 0x80) continue; // continuation byte
      final need = b < 0x80
          ? 1
          : (b & 0xE0) == 0xC0
              ? 2
              : (b & 0xF0) == 0xE0
                  ? 3
                  : (b & 0xF8) == 0xF0
                      ? 4
                      : 1; // invalid lead: let allowMalformed handle it
      if (i + need > all.length) cut = i;
      break;
    }
    _utf8Carry = cut < all.length
        ? List<int>.of(all.sublist(cut))
        : const <int>[];
    if (cut > 0) {
      _text.write(utf8.decode(all.sublist(0, cut), allowMalformed: true));
    }
    // The server's ring is 256 KB; keep a little headroom so a long-lived tab
    // cannot grow without bound.
    const cap = 512 * 1024;
    if (_text.length > cap) {
      final current = _text.toString();
      _text
        ..clear()
        ..write(current.substring(current.length - 256 * 1024));
    }
  }
}

/// The open-order registry shared by every channel on one multiplexer.
class _PtyOpenScope {
  final Map<String, List<CloudPtyChannel>> _queues =
      <String, List<CloudPtyChannel>>{};

  /// ptyId → the channel that claimed it (used to route an unbound error).
  final Map<String, CloudPtyChannel> owners = <String, CloudPtyChannel>{};

  List<CloudPtyChannel> queueFor(String sessionId) =>
      _queues.putIfAbsent(sessionId, () => <CloudPtyChannel>[]);

  void enqueue(String sessionId, CloudPtyChannel channel) =>
      queueFor(sessionId).add(channel);
}
