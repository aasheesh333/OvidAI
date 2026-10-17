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
    unawaited(_send(<String, Object?>{
      'op': 'pty_open',
      'sessionId': sessionId,
      'cols': cols,
      'rows': rows,
    }));
  }

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
  int? _exitCode;
  CloudWsError? _error;

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
    if (ptyId == null) return; // sent with pty_open dimensions on open
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
    }
    await _sub?.cancel();
    _sub = null;
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
    if (_closed) return;
    final op = frame['op'];
    final ptyId = frame['ptyId'];
    if (ptyId is String && _ptyId != null && ptyId != _ptyId) return;

    switch (op) {
      case 'pty_opened':
        if (frame['sessionId'] != sessionId) return;
        if (_ptyId == null) {
          _ptyId = ptyId is String ? ptyId : null;
          _opened = true;
          final queued = List<List<int>>.from(_queuedWrites);
          _queuedWrites.clear();
          for (final bytes in queued) {
            if (_ptyId != null) _sendInput(_ptyId!, bytes);
          }
          notifyListeners();
        }
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
      case 'error':
        _error = CloudWsError(
          (frame['code'] as String?) ?? 'internal',
          (frame['message'] as String?) ?? 'Terminal error.',
        );
        notifyListeners();
    }
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
    _text.write(utf8.decode(bytes, allowMalformed: true));
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
