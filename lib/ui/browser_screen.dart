import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/cloud/browser_stream.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/cloud_ws.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Cloud browser — a live VIEWER over the user's ONE server-side Chromium.
///
/// Wave 5 (owner rules R2/R3):
///
///  * The cloud browser is one per user, shared by every chat. Opening this
///    screen attaches to whatever page the agent has open in ANY of the
///    user's chats: the mapped server id when the chat has one, otherwise
///    [BrowserStreamClient.userAlias] (an unsent chat still sees the browser).
///  * The worker streams 3–5 fps only while someone watches. Closing the
///    screen, or backgrounding the app, sends `browser_detach`: the worker
///    keeps rendering for a 45 s grace window (so a quick re-open is
///    seamless), then converts to headless and stops frames. Coming back
///    re-attaches.
///  * Tabs are AGENT-OWNED: the strip lists what the agent opened and lets
///    the user select one; there is no client-side "new tab".
///  * Take control / Resume agent is server-acknowledged with a pending state
///    and a timeout, offered only while a live page exists (EM-019), and
///    scoped to this viewer: another device's control is shown read-only
///    (FE-026).
///  * While in control the user can tap, double-tap, long-press, scroll
///    (natural direction, streamed while the finger moves — FE-009), pinch to
///    zoom the view (one finger pans a zoomed page) and type through the soft
///    keyboard incl. Enter/Tab/Backspace/arrows (FE-008).
///
/// There is deliberately no omnibar navigation: navigation is the agent's
/// `browser_navigate` tool. The address row is a read-only display; "Open in
/// browser" hands the URL to the system browser.
class BrowserScreen extends StatefulWidget {
  /// The chat the screen was opened from (LOCAL id or server id). Only used
  /// to pick the attach id; every chat shows the same per-user browser.
  final String? sessionId;

  /// Test seam: inject a configured client instead of the process singleton.
  final BrowserStreamClient? client;

  /// How long the viewer shows "Connecting…" before it says the agent is not
  /// using the browser (the worker sends nothing while no browser is live).
  final Duration firstStateTimeout;

  const BrowserScreen({
    super.key,
    this.sessionId,
    this.client,
    this.firstStateTimeout = const Duration(seconds: 5),
  });

  /// Push the browser (defaults to the active chat).
  static Future<void> open(
    BuildContext context, {
    String? sessionId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowserScreen(sessionId: sessionId),
      ),
    );
  }

  /// Friendly copy for a browser-channel error code (FE-020: never a raw
  /// code on screen).
  static String errorCopy(BrowserStreamError error) {
    switch (error.code) {
      case 'forbidden':
        return "This chat isn't on your account, so its browser can't be shown.";
      case 'unavailable':
        return 'The cloud browser is not available right now.';
      case 'unauthenticated':
        return 'Your sign-in expired. Sign in again to view the browser.';
      default:
        return "Couldn't connect to the cloud browser.";
    }
  }

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver {
  /// Live scroll cadence: wheel deltas are coalesced and sent this often
  /// while the finger moves (FE-009), never only on finger-up.
  static const Duration _scrollFlushInterval = Duration(milliseconds: 50);

  /// The hidden keyboard field always holds this sentinel; anything typed
  /// after it is inserted, anything deleted from it is a Backspace.
  static const String _kSentinel = '​​';

  late final BrowserStreamClient _client;
  late final String _localSessionId;

  /// The id `browser_attach` was sent with (server chat id or user alias).
  String? _attachId;

  StreamSubscription<BrowserFrame>? _framesSub;
  BrowserFrame? _frame;

  Timer? _waitTimer;
  bool _waitExpired = false;

  /// True while the app is backgrounded: the attach is dropped so the worker
  /// stops encoding frames nobody can see.
  bool _backgrounded = false;

  /// The attach generation [frame] was received under.
  int _frameGeneration = -1;

  /// Decoded images released after the frame that replaced them has painted.
  final Set<ui.Image> _pendingRelease = <ui.Image>{};

  // Scroll coalescing (canvas-local logical pixels).
  Offset _pendingScroll = Offset.zero;
  Offset _scrollAnchor = Offset.zero;
  Size _scrollBox = Size.zero;
  Timer? _scrollTimer;

  // Pinch-zoom / zoomed-pan (Wave 6 W4). Client-side view transform only:
  // input coordinates are divided back through the same transform, so the
  // page never sees a zoom event.
  static const double _maxZoom = 4.0;
  double _zoom = 1.0;
  Offset _zoomPan = Offset.zero;
  double _scaleStartZoom = 1.0;
  Offset _scaleStartFocal = Offset.zero;
  double _scaleStartLeft = 0;
  double _scaleStartTop = 0;
  int _scalePointers = 0;
  Offset _panStartZoomPan = Offset.zero;

  // Soft keyboard bridge (FE-008).
  final TextEditingController _keyboard =
      TextEditingController(text: _kSentinel);
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'browser-keyboard');
  bool _keyboardOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client ?? BrowserStreamClient.I;
    _localSessionId = widget.sessionId ?? AppState.I.activeSession?.id ?? '';
    _client.addListener(_onClientChanged);
    _framesSub = _client.frames.listen(_onFrame);
    _keyboardFocus.addListener(_onKeyboardFocusChanged);
    unawaited(_attach());
  }

  /// The attach id: the chat's server id when it has one, else the user
  /// alias. Both reach the same per-user browser; an unsent chat never puts
  /// a local id on the wire (FE-020).
  Future<String> _resolveAttachId() async {
    if (_localSessionId.isEmpty) return BrowserStreamClient.userAlias;
    try {
      final store = CloudSessionStore.I;
      await store.ready;
      return store.knownServerIdFor(_localSessionId) ??
          BrowserStreamClient.userAlias;
    } catch (_) {
      // No cloud store (isolated widget test): the alias still works.
      return BrowserStreamClient.userAlias;
    }
  }

  Future<void> _attach() async {
    _startWaitTimer();
    final id = _attachId ?? await _resolveAttachId();
    if (!mounted || _backgrounded) return;
    _attachId = id;
    await _client.attach(id);
  }

  void _startWaitTimer() {
    _waitTimer?.cancel();
    _waitExpired = false;
    _waitTimer = Timer(widget.firstStateTimeout, () {
      if (!mounted) return;
      if (_frame == null && _client.state == null && _client.error == null) {
        setState(() => _waitExpired = true);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_backgrounded) return;
        _backgrounded = true;
        _waitTimer?.cancel();
        _flushScroll();
        // R3: nobody can see the canvas — stop the screencast server-side.
        _client.detach();
      case AppLifecycleState.resumed:
        if (!_backgrounded) return;
        _backgrounded = false;
        _clearFrame();
        unawaited(_attach());
      case AppLifecycleState.inactive:
        // Transient (notification shade, app switcher): keep streaming.
        break;
    }
  }

  void _onClientChanged() {
    if (!mounted) return;
    final generation = _client.generation;
    final stale = _frame != null && generation != _frameGeneration;
    final old = stale ? _frame : null;
    if (_client.state != null || _client.error != null) {
      _waitTimer?.cancel();
    }
    if (!_client.takeoverActive && _keyboardOpen) _closeKeyboard();
    setState(() {
      if (stale) _frame = null;
      if (_client.state != null || _client.error != null) {
        _waitExpired = false;
      }
      // Leaving Take Control also leaves the zoomed view.
      if (!_client.takeoverActive && (_zoom != 1.0 || _zoomPan != Offset.zero)) {
        _zoom = 1.0;
        _zoomPan = Offset.zero;
      }
    });
    _releaseFrame(old);
    final notice = _client.notice;
    if (notice != null) {
      _client.clearNotice();
      final text = notice.code == 'not_controller'
          ? 'The browser is being controlled on another device.'
          : 'Reconnecting to the browser…';
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text)));
      if (notice.code == 'not_attached' && _attachId != null) {
        unawaited(_client.attach(_attachId!));
      }
    }
  }

  void _onFrame(BrowserFrame frame) {
    if (!mounted) return;
    _waitTimer?.cancel();
    final old = _frame;
    setState(() {
      _frame = frame;
      _frameGeneration = _client.generation;
      _waitExpired = false;
    });
    _releaseFrame(old);
  }

  /// Disposes a replaced decoded image only AFTER the frame that swapped it
  /// out has been painted, so the render tree never draws a released image.
  void _releaseFrame(BrowserFrame? frame) {
    final image = frame?.image;
    if (image == null) return;
    if (!_pendingRelease.add(image)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingRelease.remove(image)) image.dispose();
    });
  }

  void _clearFrame() {
    final old = _frame;
    setState(() {
      _frame = null;
      _frameGeneration = -1;
      _waitExpired = false;
    });
    _releaseFrame(old);
  }

  /// Retry an errored/idle attach: tear the old one down and attach again.
  void _retry() {
    _clearFrame();
    _client.detach();
    unawaited(_attach());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waitTimer?.cancel();
    _waitTimer = null;
    _scrollTimer?.cancel();
    _client.removeListener(_onClientChanged);
    unawaited(_framesSub?.cancel());
    final image = _frame?.image;
    _frame = null;
    if (image != null && _pendingRelease.remove(image)) image.dispose();
    // R3: closing the viewer detaches. The worker keeps rendering for the
    // 45 s grace window, then converts to headless (and releases any
    // takeover this viewer held).
    _client.detach();
    _keyboardFocus.removeListener(_onKeyboardFocusChanged);
    _keyboardFocus.dispose();
    _keyboard.dispose();
    super.dispose();
  }

  String _host(String? url) {
    final parsed = Uri.tryParse(url ?? '');
    final host = parsed?.host ?? '';
    return host.isEmpty ? (url ?? '') : host;
  }

  String _path(String? url) {
    final parsed = Uri.tryParse(url ?? '');
    if (parsed == null || parsed.host.isEmpty) return '';
    final path = parsed.path == '/' ? '' : parsed.path;
    final query = parsed.hasQuery ? '?${parsed.query}' : '';
    return '$path$query';
  }

  Future<void> _openExternal(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing handles it — the address stays visible.
    }
  }

  double? _scaleFor(Size box) {
    final s = _client.state;
    if (s == null) return null;
    final scale = math.min(
      box.width / math.max(s.viewportWidth, 1),
      box.height / math.max(s.viewportHeight, 1),
    );
    if (scale <= 0 || !scale.isFinite) return null;
    return scale;
  }

  /// The displayed image rect for the current zoom/pan. `scale` is page CSS
  /// px → canvas px (base contain scale × zoom).
  _FrameLayout? _layout(Size box) {
    final base = _scaleFor(box);
    final s = _client.state;
    if (base == null || s == null) return null;
    final baseW = s.viewportWidth * base;
    final baseH = s.viewportHeight * base;
    final width = baseW * _zoom;
    final height = baseH * _zoom;
    final left = box.width / 2 - width / 2 + _zoomPan.dx;
    final top = box.height / 2 - height / 2 + _zoomPan.dy;
    return _FrameLayout(
      scale: base * _zoom,
      left: left,
      top: top,
      width: width,
      height: height,
    );
  }

  /// Page CSS pixels for a canvas-local point. The image is painted with the
  /// same rect [layout] computes, so this is the exact inverse transform.
  ({double x, double y})? _toPage(Offset local, Size box) {
    final s = _client.state;
    final layout = _layout(box);
    if (s == null || layout == null) return null;
    final x = ((local.dx - layout.left) / layout.scale)
        .clamp(0, s.viewportWidth - 1)
        .toDouble();
    final y = ((local.dy - layout.top) / layout.scale)
        .clamp(0, s.viewportHeight - 1)
        .toDouble();
    return (x: x, y: y);
  }

  /// Keep the zoomed image from sliding completely out of the canvas.
  Offset _clampPan(Size box, double zoom, Offset pan) {
    final s = _client.state;
    final base = _scaleFor(box);
    if (s == null || base == null) return Offset.zero;
    final width = s.viewportWidth * base * zoom;
    final height = s.viewportHeight * base * zoom;
    var left = box.width / 2 - width / 2 + pan.dx;
    var top = box.height / 2 - height / 2 + pan.dy;
    if (width <= box.width) {
      left = (box.width - width) / 2;
    } else {
      left = left.clamp(box.width - width, 0.0).toDouble();
    }
    if (height <= box.height) {
      top = (box.height - height) / 2;
    } else {
      top = top.clamp(box.height - height, 0.0).toDouble();
    }
    return Offset(
      left - (box.width / 2 - width / 2),
      top - (box.height / 2 - height / 2),
    );
  }

  void _resetZoom() {
    if (_zoom == 1.0 && _zoomPan == Offset.zero) return;
    setState(() {
      _zoom = 1.0;
      _zoomPan = Offset.zero;
    });
  }

  // ---- Pinch zoom + scroll (Wave 6 W4) ------------------------------------

  void _onScaleStart(ScaleStartDetails details, Size box) {
    _scalePointers = details.pointerCount;
    if (details.pointerCount >= 2) {
      final layout = _layout(box);
      _scaleStartZoom = _zoom;
      _scaleStartFocal = details.localFocalPoint;
      _scaleStartLeft = layout?.left ?? 0;
      _scaleStartTop = layout?.top ?? 0;
      return;
    }
    if (_zoom > 1.0) {
      // Zoomed in: one finger pans the image.
      _panStartZoomPan = _zoomPan;
    } else {
      _onPanStart(details.localFocalPoint, box);
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size box) {
    if (details.pointerCount != _scalePointers) {
      // A finger joined/left mid-gesture: re-baseline so the scale factor
      // stays relative to the current span instead of jumping.
      _scalePointers = details.pointerCount;
      final layout = _layout(box);
      _scaleStartZoom = _zoom;
      _scaleStartFocal = details.localFocalPoint;
      _scaleStartLeft = layout?.left ?? 0;
      _scaleStartTop = layout?.top ?? 0;
      _panStartZoomPan = _zoomPan;
      return;
    }
    if (details.pointerCount >= 2) {
      final next = (_scaleStartZoom * details.scale).clamp(1.0, _maxZoom).toDouble();
      // Keep the base-image point that was under the initial focal point
      // under the CURRENT focal point.
      final baseX = (_scaleStartFocal.dx - _scaleStartLeft) / _scaleStartZoom;
      final baseY = (_scaleStartFocal.dy - _scaleStartTop) / _scaleStartZoom;
      final s = _client.state;
      final base = _scaleFor(box);
      if (s == null || base == null) return;
      final width = s.viewportWidth * base * next;
      final height = s.viewportHeight * base * next;
      final left = details.localFocalPoint.dx - baseX * next;
      final top = details.localFocalPoint.dy - baseY * next;
      final pan = Offset(
        left - (box.width / 2 - width / 2),
        top - (box.height / 2 - height / 2),
      );
      setState(() {
        _zoom = next;
        _zoomPan = _clampPan(box, next, pan);
      });
      return;
    }
    if (_zoom > 1.0) {
      setState(() {
        _zoomPan = _clampPan(
          box,
          _zoom,
          _panStartZoomPan + (details.localFocalPoint - _scaleStartFocal),
        );
      });
    } else {
      _onPanUpdate(
        details.localFocalPoint,
        details.focalPointDelta,
        box,
      );
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _scalePointers = 0;
    if (_zoom <= 1.0) _onPanEnd();
  }

  // ---- Scroll (FE-009) -----------------------------------------------------

  void _onPanStart(Offset local, Size box) {
    _pendingScroll = Offset.zero;
    _scrollAnchor = local;
    _scrollBox = box;
  }

  void _onPanUpdate(Offset local, Offset delta, Size box) {
    _pendingScroll += delta;
    _scrollAnchor = local;
    _scrollBox = box;
    _scrollTimer ??= Timer(_scrollFlushInterval, _flushScroll);
  }

  void _onPanEnd() => _flushScroll();

  /// Sends the coalesced drag as ONE wheel event. Touch convention: the page
  /// follows the finger, so a finger moving UP (negative dy) scrolls the page
  /// DOWN (positive wheel dy) — the wheel delta is the negated drag.
  void _flushScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    final drag = _pendingScroll;
    _pendingScroll = Offset.zero;
    if (drag == Offset.zero) return;
    final scale = _scaleFor(_scrollBox);
    if (scale == null) return;
    final point = _toPage(_scrollAnchor, _scrollBox);
    _client.sendScroll(
      -drag.dx / scale,
      -drag.dy / scale,
      x: point?.x,
      y: point?.y,
    );
  }

  // ---- Keyboard (FE-008) ---------------------------------------------------

  void _onKeyboardFocusChanged() {
    if (!mounted) return;
    setState(() => _keyboardOpen = _keyboardFocus.hasFocus);
  }

  void _openKeyboard() {
    _resetKeyboardField();
    _keyboardFocus.requestFocus();
    unawaited(SystemChannels.textInput
        .invokeMethod<void>('TextInput.show')
        .catchError((Object _) {}));
  }

  void _closeKeyboard() {
    _keyboardFocus.unfocus();
  }

  void _resetKeyboardField() {
    _keyboard.value = const TextEditingValue(
      text: _kSentinel,
      selection: TextSelection.collapsed(offset: _kSentinel.length),
    );
  }

  /// Diff against the sentinel: appended text is inserted (newlines press
  /// Enter), characters deleted from the sentinel are Backspaces.
  void _onKeyboardChanged(String value) {
    if (value == _kSentinel) return;
    if (value.startsWith(_kSentinel)) {
      final typed = value.substring(_kSentinel.length);
      final parts = typed.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (i > 0) _client.sendKey('Enter');
        _client.sendText(parts[i]);
      }
    } else {
      final removed = math.max(1, _kSentinel.length - value.length);
      for (var i = 0; i < removed; i++) {
        _client.sendKey('Backspace');
      }
    }
    _resetKeyboardField();
  }

  void _pressKey(String key) => _client.sendKey(key);

  Widget? _controlChip() {
    final state = _client.state;
    // EM-019: nothing to control without a live page — no chip at all.
    if (state == null || !state.live || _client.error != null) return null;
    if (_client.reconnecting) return null;
    if (_client.controlledElsewhere) {
      return _ControlChip(
        key: const ValueKey('browser-elsewhere'),
        label: 'Controlled on another device',
        action: 'Take over here',
        onPressed: () => unawaited(_client.requestTakeover()),
      );
    }
    if (_client.takeoverActive) {
      return _ControlChip(
        key: const ValueKey('browser-release'),
        label: _client.takeoverPending
            ? 'Handing control back…'
            : "You're in control",
        leading: IconButton(
          key: const ValueKey('browser-keyboard'),
          tooltip: _keyboardOpen ? 'Hide keyboard' : 'Keyboard',
          icon: Icon(
            _keyboardOpen ? Icons.keyboard_hide : Icons.keyboard,
            size: 19,
          ),
          onPressed: _keyboardOpen ? _closeKeyboard : _openKeyboard,
        ),
        action: 'Resume agent',
        onPressed: _client.takeoverPending
            ? null
            : () => unawaited(_client.releaseTakeover()),
      );
    }
    if (_client.takeoverPending) {
      return const _ControlChip(
        key: ValueKey('browser-takeover-pending'),
        label: 'Taking control…',
        busy: true,
      );
    }
    if (_client.takeoverFailed) {
      return _ControlChip(
        key: const ValueKey('browser-takeover-failed'),
        label: "Couldn't take control",
        action: 'Try again',
        onPressed: () => unawaited(_client.requestTakeover()),
      );
    }
    return _ControlChip(
      key: const ValueKey('browser-takeover'),
      label: 'Agent is driving',
      action: 'Take control',
      onPressed: () => unawaited(_client.requestTakeover()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _client.state;
    final takeover = _client.takeoverActive;
    final online = !_client.reconnecting;
    final textScaler = MediaQuery.textScalerOf(context);
    final actions = <Widget>[
      if (state?.url != null && state!.url!.isNotEmpty)
        IconButton(
          tooltip: 'Open in browser',
          icon: const Icon(Icons.open_in_new, size: 19),
          onPressed: () => _openExternal(state.url!),
        ),
    ];
    final stackedActions =
        MediaQuery.sizeOf(context).width < textScaler.scale(300);
    final chip = _controlChip();

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('browser-close'),
          tooltip: 'Close browser',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Browser'),
        toolbarHeight: math.max(56, textScaler.scale(22) * 1.4 + 16),
        bottom: stackedActions
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              )
            : null,
        actions: [
          if (!stackedActions) ...actions,
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _TabStrip(
              tabs: state?.tabs ?? const <BrowserTab>[],
              live: state?.live ?? false,
              onSelect: (index) => unawaited(_client.switchTab(index)),
            ),
            _AddressRow(
              host: _host(state?.url),
              path: _path(state?.url),
              secure: (state?.url ?? '').startsWith('https:'),
              live: state?.live ?? false,
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _FrameCanvas(
                      key: const ValueKey('browser-canvas'),
                      frame: _frame,
                      state: state,
                      online: online,
                      connected: _client.linkState == WsLinkState.online,
                      takeover: takeover,
                      error: _client.error,
                      waitExpired: _waitExpired,
                      zoom: _zoom,
                      zoomPan: _zoomPan,
                      onRetry: _retry,
                      onTap: (local, box) {
                        final point = _toPage(local, box);
                        if (point != null) _client.sendTap(point.x, point.y);
                      },
                      onDoubleTap: (local, box) {
                        final point = _toPage(local, box);
                        if (point != null) {
                          _client.sendDoubleTap(point.x, point.y);
                        }
                      },
                      onLongPress: (local, box) {
                        final point = _toPage(local, box);
                        if (point != null) {
                          _client.sendLongPress(point.x, point.y);
                        }
                      },
                      onScaleStart: _onScaleStart,
                      onScaleUpdate: _onScaleUpdate,
                      onScaleEnd: _onScaleEnd,
                    ),
                  ),
                  if (_zoom > 1.0)
                    Positioned(
                      right: 10,
                      top: 10,
                      child: Material(
                        key: const ValueKey('browser-zoom'),
                        color: Aether.surface,
                        elevation: 2,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _resetZoom,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${_zoom.toStringAsFixed(1)}×',
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.zoom_out_map, size: 13),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!online && _frame != null)
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 8,
                      child: Center(child: _ReconnectBanner()),
                    ),
                  // The hidden field that carries the soft keyboard.
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 1,
                    height: 1,
                    child: Opacity(
                      opacity: 0,
                      child: TextField(
                        key: const ValueKey('browser-keyboard-field'),
                        controller: _keyboard,
                        focusNode: _keyboardFocus,
                        enabled: takeover,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.go,
                        onChanged: _onKeyboardChanged,
                        onSubmitted: (_) {
                          _client.sendKey('Enter');
                          _resetKeyboardField();
                          _keyboardFocus.requestFocus();
                        },
                      ),
                    ),
                  ),
                  if (chip != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(child: chip),
                    ),
                ],
              ),
            ),
            if (takeover && _keyboardOpen)
              _KeyBar(
                onKey: _pressKey,
                onHide: _closeKeyboard,
              ),
          ],
        ),
      ),
    );
  }
}

/// The painted image rect (canvas-local) for the current contain-scale and
/// pinch zoom. Shared by the painter and the input coordinate inverse.
class _FrameLayout {
  const _FrameLayout({
    required this.scale,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// Page CSS px → canvas px.
  final double scale;
  final double left;
  final double top;
  final double width;
  final double height;
}

/// The agent's tab strip. Wave 6 W4: tabs are AGENT-OWNED — this widget has
/// no "+" affordance and no create callback; an empty list renders nothing.
class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.live,
    required this.onSelect,
  });

  final List<BrowserTab> tabs;
  final bool live;
  final ValueChanged<int> onSelect;

  String _label(BrowserTab tab) {
    if (tab.title != null && tab.title!.isNotEmpty) return tab.title!;
    final host = Uri.tryParse(tab.url ?? '')?.host ?? '';
    if (host.isNotEmpty) return host;
    return tab.url ?? 'Tab ${tab.index + 1}';
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to show before the agent opens its first page. This is the
    // "empty browser" state — deliberately no tab-creation control.
    if (tabs.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('browser-tab-strip'),
      height: 44,
      color: Aether.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final tab = tabs[i];
          return Material(
            key: ValueKey('browser-tab-${tab.index}'),
            color: tab.active ? Aether.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: tab.active ? null : () => onSelect(tab.index),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: tab.active ? Aether.accent : Aether.hairline,
                  ),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      tab.active && live
                          ? Icons.public
                          : Icons.public_off,
                      size: 13,
                      color: tab.active && live
                          ? Aether.accent
                          : Aether.textFaint,
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        _label(tab),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: tab.active
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Read-only address display: the host stands out (a page title can spoof a
/// site); the path follows in a quieter tone.
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.host,
    required this.path,
    required this.secure,
    required this.live,
  });

  final String host;
  final String path;
  final bool secure;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final height = math.max(48.0, textScaler.scale(14) * 1.5 + 24);
    return AetherGradientHeader(
      height: height + 18,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
        child: Container(
          key: const ValueKey('browser-url-field'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            children: [
              Icon(
                secure ? Icons.lock_outline : Icons.public,
                size: 14,
                color: Aether.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  host.isEmpty ? (live ? 'Loading…' : 'No page open') : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (path.isNotEmpty)
                Expanded(
                  child: Text(
                    path,
                    key: const ValueKey('browser-url-path'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: Aether.textFaint),
                  ),
                )
              else
                const Spacer(),
              if (!secure && host.isNotEmpty)
                Text(
                  'Not secure',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Aether.warn,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screencast surface. Gestures are ignored unless takeover is active;
/// the client enforces the same rule independently (defence in depth).
class _FrameCanvas extends StatelessWidget {
  const _FrameCanvas({
    super.key,
    required this.frame,
    required this.state,
    required this.online,
    required this.connected,
    required this.takeover,
    required this.error,
    required this.waitExpired,
    required this.zoom,
    required this.zoomPan,
    required this.onRetry,
    required this.onTap,
    required this.onDoubleTap,
    required this.onLongPress,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
  });

  final BrowserFrame? frame;
  final BrowserState? state;
  final bool online;

  /// The shared socket is up (false during the first connect or when the
  /// device is offline from the start).
  final bool connected;
  final bool takeover;
  final BrowserStreamError? error;
  final bool waitExpired;
  final double zoom;
  final Offset zoomPan;
  final VoidCallback onRetry;
  final void Function(Offset local, Size box) onTap;
  final void Function(Offset local, Size box) onDoubleTap;
  final void Function(Offset local, Size box) onLongPress;
  final void Function(ScaleStartDetails details, Size box) onScaleStart;
  final void Function(ScaleUpdateDetails details, Size box) onScaleUpdate;
  final void Function(ScaleEndDetails details) onScaleEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final image = frame;
        if (image == null || error != null) {
          return Container(
            color: Aether.bg,
            alignment: Alignment.center,
            child: _placeholder(),
          );
        }
        var doubleTapAt = Offset.zero;
        return IgnorePointer(
          ignoring: !takeover,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => onTap(details.localPosition, box),
            onDoubleTapDown: (details) => doubleTapAt = details.localPosition,
            onDoubleTap: () => onDoubleTap(doubleTapAt, box),
            onLongPressStart: (details) =>
                onLongPress(details.localPosition, box),
            // One recognizer for both gestures: one finger scrolls the page
            // (or pans a zoomed view), two fingers pinch-zoom (Wave 6 W4).
            onScaleStart: (details) => onScaleStart(details, box),
            onScaleUpdate: (details) => onScaleUpdate(details, box),
            onScaleEnd: onScaleEnd,
            child: Container(
              color: Aether.bg,
              child: Opacity(
                opacity: online ? 1 : 0.55,
                child: _positionedFrame(box),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Paint the frame at the zoom/pan rect. The same rect drives input
  /// coordinate inversion in the screen state, so a tap lands where the user
  /// sees it even while zoomed.
  Widget _positionedFrame(Size box) {
    final image = frame;
    final s = state;
    if (image == null || s == null) return const SizedBox.shrink();
    final base = math.min(
      box.width / math.max(s.viewportWidth, 1),
      box.height / math.max(s.viewportHeight, 1),
    );
    final width = s.viewportWidth * base * zoom;
    final height = s.viewportHeight * base * zoom;
    final left = box.width / 2 - width / 2 + zoomPan.dx;
    final top = box.height / 2 - height / 2 + zoomPan.dy;
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: _FrameImage(frame: image),
        ),
      ],
    );
  }

  Widget _status({
    required String key,
    required String title,
    String? detail,
    bool busy = false,
    IconData? icon,
    String? action,
  }) {
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (icon != null)
            Icon(icon, size: 28, color: Aether.textMuted),
          const SizedBox(height: 12),
          Text(
            title,
            key: const ValueKey('browser-status'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('browser-retry'),
              onPressed: onRetry,
              child: Text(action),
            ),
          ],
        ],
      ),
    );
  }

  Widget _placeholder() {
    final failure = error;
    if (failure != null) {
      return _status(
        key: 'browser-error',
        title: 'Browser unavailable',
        detail: BrowserScreen.errorCopy(failure),
        icon: Icons.cloud_off,
        action: 'Retry',
      );
    }
    if (!online) {
      return _status(
        key: 'browser-offline',
        title: 'Reconnecting…',
        detail: "You're offline. The live view resumes when the connection is back.",
        busy: true,
      );
    }
    final s = state;
    if (s == null && waitExpired && !connected) {
      return _status(
        key: 'browser-offline',
        title: "You're offline",
        detail: 'The live view connects when the connection is back.',
        icon: Icons.cloud_off,
        action: 'Try again',
      );
    }
    if (s == null && !waitExpired) {
      return _status(
        key: 'browser-loading',
        title: 'Connecting to the cloud browser…',
        busy: true,
      );
    }
    if (s == null || !s.live) {
      return _status(
        key: 'browser-idle',
        title: "The agent isn't using the browser right now",
        detail: 'This view shows its page as soon as the agent opens one.',
        icon: Icons.public_off,
        action: 'Check again',
      );
    }
    return _status(
      key: 'browser-loading',
      title: 'Loading the page…',
      busy: true,
    );
  }
}

/// Paints the already-decoded engine image. The production decoder returns
/// the `ui.Image` it decoded to learn the dimensions, so this never decodes
/// the same bytes a second time. A test decoder without an image falls back
/// to [Image.memory].
class _FrameImage extends StatelessWidget {
  const _FrameImage({required this.frame});

  final BrowserFrame frame;

  @override
  Widget build(BuildContext context) {
    final image = frame.image;
    if (image != null) {
      return RawImage(
        image: image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    return Image.memory(
      frame.webpBytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('browser-reconnecting'),
      color: Aether.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(18),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Reconnecting…', style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Keys the soft keyboard lacks, shown while typing into the page.
class _KeyBar extends StatelessWidget {
  const _KeyBar({required this.onKey, required this.onHide});

  final void Function(String key) onKey;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    Widget key(String id, String label, String keyName) => TextButton(
          key: ValueKey('browser-key-$id'),
          onPressed: () => onKey(keyName),
          child: Text(label),
        );
    return Container(
      color: Aether.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            key('tab', 'Tab', 'Tab'),
            key('enter', 'Enter', 'Enter'),
            key('backspace', 'Delete', 'Backspace'),
            key('escape', 'Esc', 'Escape'),
            key('left', '←', 'ArrowLeft'),
            key('up', '↑', 'ArrowUp'),
            key('down', '↓', 'ArrowDown'),
            key('right', '→', 'ArrowRight'),
            key('home', 'Home', 'Home'),
            key('end', 'End', 'End'),
            IconButton(
              tooltip: 'Hide keyboard',
              icon: const Icon(Icons.keyboard_hide, size: 19),
              onPressed: onHide,
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlChip extends StatelessWidget {
  const _ControlChip({
    super.key,
    required this.label,
    this.action,
    this.onPressed,
    this.leading,
    this.busy = false,
  });

  final String label;
  final String? action;
  final VoidCallback? onPressed;
  final Widget? leading;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Aether.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: EdgeInsets.fromLTRB(leading == null ? 14 : 4, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?leading,
            if (busy) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: action == null ? 10 : 0),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: onPressed,
                child: Text(action!),
              ),
            ] else
              const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}
