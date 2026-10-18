/// Client side of the P6 browser screencast channel (P8 Task 16).
///
/// The BUILT server is the contract — this file mirrors
/// `cloud/packages/shared/src/browser.ts` and the gateway's browser ops in
/// `cloud/apps/gateway/src/ws.ts`:
///
///  - client → server: `browser_attach{sessionId}`,
///    `browser_detach{sessionId}`, `browser_input{sessionId,input}`,
///    `browser_takeover{sessionId,enabled}`;
///  - server → client: `browser_state{state}` (JSON) and screencast frames as
///    raw BINARY WS messages — image bytes only. The gateway strips redis's
///    1-byte `BROWSER_FRAME_FORMAT` prefix before forwarding; the image format
///    travels in the latest `browser_state.frameFormat`.
///
/// ## Deviations from the plan's pinned client interface (server wins)
///
/// The plan pinned `BrowserTabDto`, `tabs(sessionId)` and
/// `attach(sessionId, tabId)`. The built P6 surface has NONE of those: there is
/// no browser tab-list REST route, and the gateway allows exactly ONE attach
/// per socket, keyed by `sessionId` only. The screencast shows the session's
/// ACTIVE page; `browser_state` carries its `url`/`title`/`viewport`. So this
/// client attaches by session and exposes the active tab from state — it never
/// invents a tab list the server cannot answer.
///
/// ## Takeover (spec G6)
///
/// `takeoverActive` is SERVER-ACKNOWLEDGED state, never an optimistic local
/// flag: [requestTakeover] publishes `browser_takeover{enabled:true}` and the
/// flag flips only when a subsequent `browser_state` says `takeover: true`.
/// Input calls are hard no-ops while it is false, so a tap that lands before
/// the ack can never reach the input channel. [releaseTakeover] hands control
/// back the same way.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'cloud_ws.dart';

/// One decoded screencast frame.
///
/// [webpBytes] keeps the plan's field name; the bytes are whatever
/// `BrowserState.frameFormat` says (WebP in practice, JPEG on a probe
/// fallback). [width]/[height] come from decoding the image — the binary
/// channel carries no dimensions.
class BrowserFrame {
  const BrowserFrame({
    required this.webpBytes,
    required this.width,
    required this.height,
  });

  final Uint8List webpBytes;
  final int width;
  final int height;
}

/// The server's `BrowserStateDto` (`@ovid/shared` browser.ts).
class BrowserState {
  const BrowserState({
    required this.sessionId,
    required this.live,
    required this.url,
    required this.title,
    required this.takeover,
    required this.screencast,
    required this.frameFormat,
    required this.viewportWidth,
    required this.viewportHeight,
  });

  factory BrowserState.fromJson(Map<String, dynamic> json) {
    final viewport = json['viewport'];
    final view = viewport is Map ? viewport : const <String, dynamic>{};
    return BrowserState(
      sessionId: json['sessionId'] as String? ?? '',
      live: json['live'] == true,
      url: json['url'] as String?,
      title: json['title'] as String?,
      takeover: json['takeover'] == true,
      screencast: json['screencast'] == true,
      frameFormat: json['frameFormat'] as String? ?? 'webp',
      viewportWidth: (view['width'] as num?)?.toInt() ?? 1280,
      viewportHeight: (view['height'] as num?)?.toInt() ?? 800,
    );
  }

  final String sessionId;

  /// False while the engine is (re)starting or the tab crashed.
  final bool live;

  final String? url;
  final String? title;

  /// Server-owned input-exclusivity flag.
  final bool takeover;

  /// True while the worker is streaming screencast frames.
  final bool screencast;

  /// `jpeg` or `webp` — the format of the binary frames on the wire.
  final String frameFormat;

  /// Page CSS-pixel viewport the canvas scales input coordinates against.
  final int viewportWidth;
  final int viewportHeight;
}

/// Decodes one binary screencast frame. Replaceable so a test (or a platform
/// without an image codec) can supply dimensions without decoding.
typedef BrowserFrameDecoder = Future<BrowserFrame> Function(Uint8List bytes);

/// The production decoder: the image's intrinsic size is the only dimension
/// information the binary channel provides.
Future<BrowserFrame> decodeBrowserFrame(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      return BrowserFrame(
        webpBytes: bytes,
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// One session's live browser viewer over the shared [WsMultiplexer].
///
/// The multiplexer socket is app-wide, but the gateway permits one browser
/// attach per socket, so only one session streams at a time. Binary frames
/// carry no session id; they are emitted only while [attach] is active.
class BrowserStreamClient extends ChangeNotifier {
  BrowserStreamClient({
    required WsMultiplexer ws,
    Stream<Map<String, dynamic>>? rawFramesOverride,
    Stream<Uint8List>? binaryFramesOverride,
    Future<void> Function(Map<String, Object?> frame)? sendOverride,
    BrowserFrameDecoder? decodeFrame,
  })  : _ws = ws,
        _rawFrames = rawFramesOverride ?? ws.rawServerFrames,
        _binaryFrames = binaryFramesOverride ?? ws.binaryServerFrames,
        // ignore: prefer_initializing_formals
        _sendOverride = sendOverride,
        _decodeFrame = decodeFrame ?? decodeBrowserFrame;

  static BrowserStreamClient? _instance;

  /// Process-wide default (production wiring).
  static BrowserStreamClient get I =>
      _instance ??= BrowserStreamClient(ws: WsMultiplexer.I);

  @visibleForTesting
  static void installForTest(BrowserStreamClient client) => _instance = client;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  final WsMultiplexer _ws;
  final Stream<Map<String, dynamic>> _rawFrames;
  final Stream<Uint8List> _binaryFrames;
  final Future<void> Function(Map<String, Object?> frame)? _sendOverride;
  final BrowserFrameDecoder _decodeFrame;

  StreamSubscription<Map<String, dynamic>>? _rawSub;
  StreamSubscription<Uint8List>? _binarySub;

  final StreamController<BrowserFrame> _frames =
      StreamController<BrowserFrame>.broadcast();

  String? _sessionId;
  BrowserState? _state;
  bool _takeoverActive = false;
  bool _disposed = false;

  /// Frames decode strictly in arrival order: concurrent decodes could paint
  /// an older frame last.
  Future<void> _decodeChain = Future<void>.value();

  /// Decoded screencast frames for the attached session.
  Stream<BrowserFrame> get frames => _frames.stream;

  /// Latest server state (url/title/viewport/takeover), or null before the
  /// first `browser_state`.
  BrowserState? get state => _state;

  /// The attached session id, or null when detached.
  String? get sessionId => _sessionId;

  /// Server-acknowledged input exclusivity (spec G6).
  bool get takeoverActive => _takeoverActive;

  Future<void> _send(Map<String, Object?> frame) {
    final override = _sendOverride;
    if (override != null) return override(frame);
    return _ws.sendRaw(frame);
  }

  /// Attaches this viewer to [sessionId]'s active page. A second call replaces
  /// the previous attach (the server's one-attach-per-socket rule).
  Future<void> attach(String sessionId) async {
    if (_disposed || sessionId.isEmpty) return;
    if (_sessionId == sessionId && _rawSub != null) return;
    if (_sessionId != null) detach();
    _sessionId = sessionId;
    _state = null;
    _takeoverActive = false;
    _listen();
    await _send(<String, Object?>{
      'op': 'browser_attach',
      'sessionId': sessionId,
    });
  }

  /// Detaches from the server and stops forwarding frames/states.
  void detach() {
    final id = _sessionId;
    _sessionId = null;
    _state = null;
    _takeoverActive = false;
    unawaited(_rawSub?.cancel());
    unawaited(_binarySub?.cancel());
    _rawSub = null;
    _binarySub = null;
    if (id != null && !_disposed) {
      unawaited(_send(<String, Object?>{
        'op': 'browser_detach',
        'sessionId': id,
      }));
    }
    notifyListeners();
  }

  void _listen() {
    _rawSub = _rawFrames.listen(
      _onRawFrame,
      onError: (Object error) => debugPrint('browser stream: state error: $error'),
    );
    _binarySub = _binaryFrames.listen(
      _onBinaryFrame,
      onError: (Object error) =>
          debugPrint('browser stream: frame error: $error'),
    );
  }

  void _onRawFrame(Map<String, dynamic> frame) {
    if (frame['op'] != 'browser_state') return;
    final id = _sessionId;
    if (id == null) return;
    final raw = frame['state'];
    if (raw is! Map) return;
    final json = Map<String, dynamic>.from(raw);
    if ((json['sessionId'] as String? ?? id) != id) return;
    BrowserState state;
    try {
      state = BrowserState.fromJson(json);
    } catch (err) {
      debugPrint('browser stream: off-contract state dropped: $err');
      return;
    }
    _state = state;
    _takeoverActive = state.takeover;
    notifyListeners();
  }

  void _onBinaryFrame(Uint8List bytes) {
    if (_sessionId == null || _frames.isClosed) return;
    _decodeChain = _decodeChain.then((_) async {
      if (_sessionId == null || _frames.isClosed) return;
      try {
        final frame = await _decodeFrame(bytes);
        if (_sessionId == null || _frames.isClosed) return;
        _frames.add(frame);
      } catch (err) {
        // A truncated/unsupported frame must not kill the stream.
        debugPrint('browser stream: frame decode failed: $err');
      }
    });
  }

  /// Taps the page at CSS-pixel ([x], [y]) in `state.viewport` coordinates.
  void sendTap(double x, double y) {
    _sendInput(<String, Object?>{'type': 'tap', 'x': x, 'y': y});
  }

  /// Scrolls the page by ([dx], [dy]) CSS pixels.
  void sendScroll(double dx, double dy) {
    _sendInput(<String, Object?>{'type': 'scroll', 'dx': dx, 'dy': dy});
  }

  /// Presses [key] (Playwright key name), or inserts [text] when given.
  void sendKey(String key, {String? text}) {
    if (key.isEmpty) return;
    final input = <String, Object?>{'type': 'key', 'key': key};
    if (text != null) input['text'] = text;
    _sendInput(input);
  }

  void _sendInput(Map<String, Object?> input) {
    final id = _sessionId;
    if (id == null || !_takeoverActive || _disposed) return;
    unawaited(_send(<String, Object?>{
      'op': 'browser_input',
      'sessionId': id,
      'input': input,
    }));
  }

  /// Asks the server for input exclusivity. Does NOT flip [takeoverActive] —
  /// the flag changes only when the server acknowledges via `browser_state`.
  Future<void> requestTakeover() async {
    final id = _sessionId;
    if (id == null || _disposed) return;
    await _send(<String, Object?>{
      'op': 'browser_takeover',
      'sessionId': id,
      'enabled': true,
    });
  }

  /// Hands control back to the agent. Like [requestTakeover], the local flag
  /// follows the server's next state frame.
  Future<void> releaseTakeover() async {
    final id = _sessionId;
    if (id == null || _disposed) return;
    await _send(<String, Object?>{
      'op': 'browser_takeover',
      'sessionId': id,
      'enabled': false,
    });
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionId = null;
    unawaited(_rawSub?.cancel());
    unawaited(_binarySub?.cancel());
    _rawSub = null;
    _binarySub = null;
    unawaited(_frames.close().catchError((Object _) {}));
    super.dispose();
  }
}
