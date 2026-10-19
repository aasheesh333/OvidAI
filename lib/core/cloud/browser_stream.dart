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
///
/// ## Wave 5 — one browser per user, per-viewer takeover
///
/// The cloud browser is ONE per user, shared across every chat. Any owned
/// server chat id — or [BrowserStreamClient.userAlias] for a chat that has no
/// server id yet — attaches to the same browser, so the viewer always shows
/// whatever page the agent has open. `browser_state.state.sessionId` is the
/// server's per-user key; the op-level `sessionId` echoes the id this client
/// attached with, and the op-level `viewerId` is this socket's viewer. While
/// another device holds takeover ([controlledElsewhere]) this viewer is
/// read-only.
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
///
/// [image] is the decoded frame the production decoder already produced, so
/// the viewer can paint it directly ([RawImage]) instead of decoding the
/// bytes a second time. It is null only for a test decoder that supplies
/// dimensions without an engine image. The CONSUMER owns it and must dispose
/// it once it is no longer painted.
class BrowserFrame {
  const BrowserFrame({
    required this.webpBytes,
    required this.width,
    required this.height,
    this.image,
  });

  final Uint8List webpBytes;
  final int width;
  final int height;
  final ui.Image? image;
}

/// A browser-channel `{"op":"error"}` frame (forbidden, unavailable,
/// internal, not_attached — the gateway's browser ops).
class BrowserStreamError {
  const BrowserStreamError({required this.code, required this.message});

  final String code;
  final String message;
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
    this.takeoverViewerId,
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
      takeoverViewerId: json['takeoverViewerId'] as String?,
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

  /// The gateway viewer that holds takeover (null when none, or an older
  /// server that does not say).
  final String? takeoverViewerId;
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
    // The image stays alive after the codec is disposed; the viewer paints
    // this instance and disposes it when the next frame replaces it.
    return BrowserFrame(
      webpBytes: bytes,
      width: image.width,
      height: image.height,
      image: image,
    );
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
    this.takeoverAckTimeout = const Duration(seconds: 5),
  })  : _ws = ws,
        _rawFrames = rawFramesOverride ?? ws.rawServerFrames,
        _binaryFrames = binaryFramesOverride ?? ws.binaryServerFrames,
        // ignore: prefer_initializing_formals
        _sendOverride = sendOverride,
        _decodeFrame = decodeFrame ?? decodeBrowserFrame,
        _lastLinkState = ws.linkState {
    _ws.addListener(_onLinkChanged);
  }

  static BrowserStreamClient? _instance;

  /// Attach id for "my browser" without naming a chat (the gateway's
  /// `USER_BROWSER_ALIAS`).
  static const String userAlias = 'user';

  /// Error codes that refuse ONE input/takeover op; they never replace the
  /// viewer with an error screen.
  static const Set<String> transientCodes = <String>{
    'not_controller',
    'not_attached',
  };

  /// How long "Take control" may wait for the server's acknowledgement.
  final Duration takeoverAckTimeout;

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
  BrowserStreamError? _error;
  BrowserStreamError? _notice;
  String? _viewerId;
  bool _takeoverActive = false;
  bool _controlledElsewhere = false;
  bool _takeoverPending = false;
  bool _takeoverFailed = false;
  Timer? _takeoverTimer;
  bool _disposed = false;

  /// Monotonic attach generation. Every binary frame captures the generation
  /// it arrived under and is dropped unless it is still current — frames
  /// carry no session id, so a decode queued for session A must never paint
  /// into B after a re-attach.
  int _generation = 0;

  /// Link-state tracking for reconnect recovery: the gateway tears the
  /// browser attach down with the socket, so a transition back to `online`
  /// must re-send `browser_attach`.
  WsLinkState _lastLinkState;

  /// True once this attach has been (or was queued while) online. The first
  /// offline→online transition just flushes the queued attach; every later
  /// one is a reconnect and must re-attach explicitly.
  bool _onlineSinceAttach = false;

  /// Frames decode strictly in arrival order: concurrent decodes could paint
  /// an older frame last.
  Future<void> _decodeChain = Future<void>.value();

  /// Decoded screencast frames for the attached session.
  Stream<BrowserFrame> get frames => _frames.stream;

  /// Latest server state (url/title/viewport/takeover), or null before the
  /// first `browser_state`.
  BrowserState? get state => _state;

  /// The last browser-channel error (cleared by the next `browser_state` or
  /// attach), or null.
  BrowserStreamError? get error => _error;

  /// The attach generation (bumped on attach, detach and reconnect). A
  /// viewer uses it to discard a frame painted by a previous attach.
  int get generation => _generation;

  /// The attached session id, or null when detached.
  String? get sessionId => _sessionId;

  /// Server-acknowledged input exclusivity held by THIS viewer (spec G6).
  bool get takeoverActive => _takeoverActive;

  /// Another viewer (device) holds takeover: this one is read-only (FE-026).
  bool get controlledElsewhere => _controlledElsewhere;

  /// A takeover request is waiting for the server's acknowledgement.
  bool get takeoverPending => _takeoverPending;

  /// The last takeover request was never acknowledged in time.
  bool get takeoverFailed => _takeoverFailed;

  /// There is a live page to take over (EM-019: never offer it otherwise).
  bool get canTakeOver => _state?.live == true;

  /// This socket's gateway viewer id (from `browser_state`), or null.
  String? get viewerId => _viewerId;

  /// The last transient refusal (`not_controller`, `not_attached`), or null.
  BrowserStreamError? get notice => _notice;

  /// The shared socket's link state.
  WsLinkState get linkState => _ws.linkState;

  /// The link this attach was live on dropped and has not come back yet:
  /// the last frame is stale (FE-020 "Reconnecting…" overlay). False while
  /// the very first connect is still in progress.
  bool get reconnecting =>
      _sessionId != null &&
      _onlineSinceAttach &&
      _ws.linkState != WsLinkState.online;

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
    _generation++;
    _sessionId = sessionId;
    _resetSessionState();
    _onlineSinceAttach = _ws.linkState == WsLinkState.online;
    // Session-scoped gateway errors (forbidden/unavailable/internal) carry a
    // sessionId, not a ptyId; register so the multiplexer copies them onto
    // the raw lane this client listens to.
    _ws.watchSessionErrors(sessionId);
    _listen();
    await _send(<String, Object?>{
      'op': 'browser_attach',
      'sessionId': sessionId,
    });
  }

  /// Detaches from the server and stops forwarding frames/states.
  void detach() {
    // A viewer may call this from its own dispose after the injected client
    // was already torn down (test teardown order); never touch a disposed
    // notifier.
    if (_disposed) return;
    final id = _sessionId;
    _generation++;
    _sessionId = null;
    _resetSessionState();
    _onlineSinceAttach = false;
    if (id != null) _ws.unwatchSessionErrors(id);
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

  void _resetSessionState() {
    _state = null;
    _error = null;
    _notice = null;
    _viewerId = null;
    _takeoverActive = false;
    _controlledElsewhere = false;
    _clearTakeoverPending();
    _takeoverFailed = false;
  }

  void _clearTakeoverPending() {
    _takeoverTimer?.cancel();
    _takeoverTimer = null;
    _takeoverPending = false;
  }

  /// A socket reconnect is a NEW link: the gateway's `close` handler tore the
  /// old attach down (`ws.ts`), and raw ops are not replayed. Re-send
  /// `browser_attach` and drop the stale state so the canvas cannot present a
  /// pre-reconnect frame as live.
  void _onLinkChanged() {
    final link = _ws.linkState;
    final previous = _lastLinkState;
    _lastLinkState = link;
    if (_disposed) return;
    final id = _sessionId;
    // Every link change repaints an attached viewer (FE-020: the
    // "Reconnecting…" overlay must appear the moment the link drops).
    if (id != null && link != previous) notifyListeners();
    if (link != WsLinkState.online) return;
    if (previous == WsLinkState.online) return;
    if (id == null) return;
    if (!_onlineSinceAttach) {
      // The attach was queued mid-connect; the multiplexer flushes it now.
      _onlineSinceAttach = true;
      return;
    }
    _generation++;
    _resetSessionState();
    notifyListeners();
    unawaited(_send(<String, Object?>{
      'op': 'browser_attach',
      'sessionId': id,
    }));
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
    final id = _sessionId;
    if (id == null) return;
    final op = frame['op'];
    if (op == 'error') {
      final rawId = frame['sessionId'];
      if (rawId is String && rawId.isNotEmpty && rawId != id) return;
      final code = frame['code'];
      final message = frame['message'];
      final failure = BrowserStreamError(
        code: code is String ? code : 'internal',
        message: message is String ? message : 'Unknown error.',
      );
      if (transientCodes.contains(failure.code)) {
        _notice = failure;
        if (failure.code == 'not_attached' || failure.code == 'not_controller') {
          _clearTakeoverPending();
        }
      } else {
        _error = failure;
      }
      notifyListeners();
      return;
    }
    if (op != 'browser_state') return;
    // Wave 5: the op-level sessionId echoes the id this client attached
    // with; the DTO's own sessionId is the server's per-user browser key.
    final opId = frame['sessionId'];
    if (opId is String && opId.isNotEmpty && opId != id) return;
    final raw = frame['state'];
    if (raw is! Map) return;
    final json = Map<String, dynamic>.from(raw);
    if (opId is! String || opId.isEmpty) {
      // Pre-Wave-5 gateway without an op-level id: match the DTO's.
      final rawId = json['sessionId'];
      if (rawId is String && rawId != id) return;
    }
    final viewer = frame['viewerId'];
    if (viewer is String && viewer.isNotEmpty) _viewerId = viewer;
    BrowserState state;
    try {
      state = BrowserState.fromJson(json);
    } catch (err) {
      debugPrint('browser stream: off-contract state dropped: $err');
      return;
    }
    _error = null;
    _state = state;
    final holder = state.takeoverViewerId;
    final mine = holder == null || _viewerId == null || holder == _viewerId;
    final wasActive = _takeoverActive;
    _takeoverActive = state.takeover && mine;
    _controlledElsewhere = state.takeover && !mine;
    if (_takeoverPending && _takeoverActive != wasActive) {
      // The server acknowledged the request (either direction).
      _clearTakeoverPending();
      _takeoverFailed = false;
    }
    if (!state.live) _clearTakeoverPending();
    notifyListeners();
  }

  void _onBinaryFrame(Uint8List bytes) {
    if (_sessionId == null || _frames.isClosed) return;
    final generation = _generation;
    _decodeChain = _decodeChain.then((_) async {
      if (generation != _generation ||
          _sessionId == null ||
          _frames.isClosed) {
        return;
      }
      try {
        final frame = await _decodeFrame(bytes);
        // A detach/re-attach while the decode was in flight invalidates it:
        // the bytes belong to the previous attach (binary frames carry no
        // session id). The dropped frame's decoded image is ours to release.
        if (generation != _generation ||
            _sessionId == null ||
            _frames.isClosed) {
          frame.image?.dispose();
          return;
        }
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

  /// Double-taps the page at CSS-pixel ([x], [y]).
  void sendDoubleTap(double x, double y) {
    _sendInput(<String, Object?>{'type': 'double_tap', 'x': x, 'y': y});
  }

  /// Long-presses the page at CSS-pixel ([x], [y]).
  void sendLongPress(double x, double y) {
    _sendInput(<String, Object?>{'type': 'long_press', 'x': x, 'y': y});
  }

  /// Scrolls the page by ([dx], [dy]) CSS pixels (mouse-wheel sense:
  /// positive dy reveals content BELOW). [x]/[y] target the element under
  /// the finger.
  void sendScroll(double dx, double dy, {double? x, double? y}) {
    final input = <String, Object?>{'type': 'scroll', 'dx': dx, 'dy': dy};
    if (x != null && y != null) {
      input['x'] = x;
      input['y'] = y;
    }
    _sendInput(input);
  }

  /// Presses [key] (Playwright key name: Enter, Tab, Backspace, …), or
  /// inserts [text] when given.
  void sendKey(String key, {String? text}) {
    if (key.isEmpty) return;
    final input = <String, Object?>{'type': 'key', 'key': key};
    if (text != null) input['text'] = text;
    _sendInput(input);
  }

  /// Types [text] into the focused element (IME-safe insertText).
  void sendText(String text) {
    if (text.isEmpty) return;
    sendKey('Insert', text: text);
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
    if (id == null || _disposed || !canTakeOver) return;
    _armTakeoverTimer();
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
    _armTakeoverTimer();
    await _send(<String, Object?>{
      'op': 'browser_takeover',
      'sessionId': id,
      'enabled': false,
    });
  }

  void _armTakeoverTimer() {
    _takeoverTimer?.cancel();
    _takeoverPending = true;
    _takeoverFailed = false;
    _notice = null;
    _takeoverTimer = Timer(takeoverAckTimeout, () {
      _takeoverTimer = null;
      if (_disposed || !_takeoverPending) return;
      _takeoverPending = false;
      _takeoverFailed = true;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Clears a shown transient notice.
  void clearNotice() {
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _takeoverTimer?.cancel();
    final id = _sessionId;
    _sessionId = null;
    if (id != null) _ws.unwatchSessionErrors(id);
    _ws.removeListener(_onLinkChanged);
    unawaited(_rawSub?.cancel());
    unawaited(_binarySub?.cancel());
    _rawSub = null;
    _binarySub = null;
    unawaited(_frames.close().catchError((Object _) {}));
    super.dispose();
  }
}
