import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/cloud/browser_stream.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Cloud browser — the P6 screencast (P8 Task 16).
///
/// The on-device WebView browser was removed with the thin-client migration;
/// this screen is a VIEWER over the server's live Chromium:
///
///  * binary WebP/JPEG frames render on the canvas ([BrowserStreamClient]);
///  * the tab chrome shows the server's active page (`browser_state`
///    url/title — the built P6 surface exposes no tab-list route);
///  * taps/scrolls are forwarded as `browser_input` ONLY while the user holds
///    server-acknowledged takeover (spec G6). While the agent drives, the
///    canvas ignores gestures and an "Agent is driving — Take over" button
///    requests control; the button's effect appears only when the server's
///    next `browser_state` says `takeover: true`.
///
/// There is deliberately no omnibar navigation here: the wire contract has no
/// navigation input event (navigation is the agent's `browser_navigate` tool,
/// server-side). The address row is a read-only, spoof-resistant display; a
/// link tapped in the transcript opens the SYSTEM browser instead of this
/// read-only viewer.
///
/// The `sessionId` callers pass is the local chat id; [_BrowserScreenState]
/// resolves it through `CloudSessionStore.serverIdFor` before attaching (the
/// gateway accepts only the owned server UUID).
class BrowserScreen extends StatefulWidget {
  /// Session id to attach to. This is the LOCAL `ChatSession.id` (or a server
  /// id when the caller already has one); the screen resolves it to the
  /// mapped server UUID before it sends `browser_attach`, because the
  /// gateway requires a UUID it owns.
  final String? sessionId;

  /// Test seam: inject a configured client instead of the process singleton.
  final BrowserStreamClient? client;

  const BrowserScreen({
    super.key,
    this.sessionId,
    this.client,
  });

  /// Push the browser for [sessionId] (defaults to the active chat).
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

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  /// How long "attached, but the server has not sent a state/frame yet" may
  /// look like normal startup before the viewer says the agent has not opened
  /// a page. The worker sends NOTHING for a chat with no live browser
  /// (`bridge.ts` ignores viewer_join), so an unbounded spinner is a lie.
  static const Duration _firstFrameTimeout = Duration(seconds: 8);

  late final BrowserStreamClient _client;

  /// The id the caller gave us (local chat id or already a server id).
  late final String _localSessionId;

  /// The resolved server UUID used for `browser_attach`.
  String? _serverSessionId;

  StreamSubscription<BrowserFrame>? _framesSub;
  BrowserFrame? _frame;
  Offset _drag = Offset.zero;

  Timer? _waitTimer;
  bool _waitExpired = false;

  /// The attach generation [frame] was received under. A reconnect (or a
  /// detach/re-attach) bumps the client's generation and invalidates it.
  int _frameGeneration = -1;

  /// Decoded images released after the frame that replaced them has painted.
  final Set<ui.Image> _pendingRelease = <ui.Image>{};

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? BrowserStreamClient.I;
    _localSessionId = widget.sessionId ?? AppState.I.activeSession?.id ?? '';
    _client.addListener(_onClientChanged);
    _framesSub = _client.frames.listen(_onFrame);
    if (_localSessionId.isNotEmpty) {
      // Start the bounded wait immediately: resolving the id is fast, and
      // the timeout is about the server sending no state/frame at all.
      _startWaitTimer();
      unawaited(_attachResolved());
    }
  }

  /// Resolves the local chat id to the server UUID at the boundary (the
  /// gateway rejects a non-UUID id with `forbidden`). The mapping is loaded
  /// asynchronously, so wait for the store before reading it.
  Future<void> _attachResolved() async {
    var serverId = _localSessionId;
    try {
      final store = CloudSessionStore.I;
      await store.ready;
      serverId = store.serverIdFor(_localSessionId) ?? _localSessionId;
    } catch (_) {
      // No cloud store available (isolated widget test): fall back to the id
      // we were given. Production always has the store.
    }
    if (!mounted) return;
    _serverSessionId = serverId;
    await _client.attach(serverId);
  }

  void _startWaitTimer() {
    _waitTimer?.cancel();
    _waitExpired = false;
    _waitTimer = Timer(_firstFrameTimeout, () {
      if (!mounted) return;
      if (_frame == null &&
          _client.state == null &&
          _client.error == null) {
        setState(() => _waitExpired = true);
      }
    });
  }

  void _onClientChanged() {
    if (!mounted) return;
    final generation = _client.generation;
    final stale = _frame != null && generation != _frameGeneration;
    final old = stale ? _frame : null;
    if (_client.state != null || _client.error != null) {
      _waitTimer?.cancel();
    }
    setState(() {
      if (stale) _frame = null;
      if (_client.state != null || _client.error != null) {
        _waitExpired = false;
      }
    });
    _releaseFrame(old);
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

  /// Retry an errored/timed-out attach: tear the old one down and attach
  /// again. The generation bump also clears the stale canvas.
  void _retry() {
    final id = _serverSessionId;
    if (id == null) return;
    final old = _frame;
    setState(() {
      _frame = null;
      _frameGeneration = -1;
      _waitExpired = false;
    });
    _releaseFrame(old);
    _client.detach();
    _startWaitTimer();
    unawaited(_client.attach(id));
  }

  @override
  void dispose() {
    _waitTimer?.cancel();
    _waitTimer = null;
    _client.removeListener(_onClientChanged);
    unawaited(_framesSub?.cancel());
    final image = _frame?.image;
    _frame = null;
    if (image != null && _pendingRelease.remove(image)) image.dispose();
    _client.detach();
    super.dispose();
  }

  String _host(String? url) {
    final parsed = Uri.tryParse(url ?? '');
    final host = parsed?.host ?? '';
    return host.isEmpty ? (url ?? '') : host;
  }

  Future<void> _openExternal(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing handles it — the address stays visible and copyable.
    }
  }

  /// Page CSS pixels for a canvas-local point. The image is painted with
  /// `BoxFit.contain`, so the same letterboxed rect is the coordinate space.
  ({double x, double y})? _toPage(Offset local, Size box) {
    final s = _client.state;
    if (s == null) return null;
    final scale = math.min(
      box.width / math.max(s.viewportWidth, 1),
      box.height / math.max(s.viewportHeight, 1),
    );
    if (scale <= 0 || !scale.isFinite) return null;
    final offsetX = (box.width - s.viewportWidth * scale) / 2;
    final offsetY = (box.height - s.viewportHeight * scale) / 2;
    final x = ((local.dx - offsetX) / scale)
        .clamp(0, s.viewportWidth - 1)
        .toDouble();
    final y = ((local.dy - offsetY) / scale)
        .clamp(0, s.viewportHeight - 1)
        .toDouble();
    return (x: x, y: y);
  }

  @override
  Widget build(BuildContext context) {
    final state = _client.state;
    final takeover = _client.takeoverActive;
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
              title: state?.title,
              url: state?.url,
              live: state?.live ?? false,
            ),
            _AddressRow(
              host: _host(state?.url),
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
                      live: state?.live ?? false,
                      attached: _localSessionId.isNotEmpty,
                      takeover: takeover,
                      error: _client.error,
                      waitExpired: _waitExpired,
                      onRetry: _retry,
                      onTap: (local, box) {
                        final point = _toPage(local, box);
                        if (point != null) _client.sendTap(point.x, point.y);
                      },
                      onDragStart: () => _drag = Offset.zero,
                      onDragUpdate: (delta) => _drag += delta,
                      onDragEnd: (box) {
                        final s = _client.state;
                        if (s == null || _drag.distance < 4) return;
                        final scale = math.min(
                          box.width / math.max(s.viewportWidth, 1),
                          box.height / math.max(s.viewportHeight, 1),
                        );
                        if (scale <= 0 || !scale.isFinite) return;
                        _client.sendScroll(_drag.dx / scale, _drag.dy / scale);
                      },
                    ),
                  ),
                  if (takeover)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(
                        child: _ControlChip(
                          key: const ValueKey('browser-release'),
                          label: 'You are controlling the browser',
                          action: 'Release control',
                          onPressed: () => unawaited(
                            _client.releaseTakeover(),
                          ),
                        ),
                      ),
                    )
                  else
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 12,
                      child: Center(
                        child: _ControlChip(
                          key: const ValueKey('browser-takeover'),
                          label: 'Agent is driving — Take over',
                          action: 'Take over',
                          onPressed: () => unawaited(
                            _client.requestTakeover(),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The server's active page as a single tab chip (P6 has no tab-list route).
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.title, required this.url, required this.live});

  final String? title;
  final String? url;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final label = (title?.isNotEmpty ?? false)
        ? title!
        : (Uri.tryParse(url ?? '')?.host.isNotEmpty ?? false)
            ? Uri.parse(url!).host
            : (url ?? 'Cloud browser');
    return Container(
      key: const ValueKey('browser-tab-strip'),
      height: 44,
      color: Aether.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Aether.hairline),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  live ? Icons.public : Icons.public_off,
                  size: 13,
                  color: live ? Aether.accent : Aether.textFaint,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Read-only address display: the host only (a page title can spoof a site).
class _AddressRow extends StatelessWidget {
  const _AddressRow({
    required this.host,
    required this.secure,
    required this.live,
  });

  final String host;
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
              Expanded(
                child: Text(
                  host.isEmpty
                      ? (live ? 'Waiting for the page…' : 'No page loaded')
                      : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (!secure && host.isNotEmpty)
                Text(
                  'Not secure',
                  style: TextStyle(
                    fontSize: 11.5,
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
    required this.live,
    required this.attached,
    required this.takeover,
    required this.error,
    required this.waitExpired,
    required this.onRetry,
    required this.onTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final BrowserFrame? frame;
  final bool live;
  final bool attached;
  final bool takeover;
  final BrowserStreamError? error;
  final bool waitExpired;
  final VoidCallback onRetry;
  final void Function(Offset local, Size box) onTap;
  final VoidCallback onDragStart;
  final void Function(Offset delta) onDragUpdate;
  final void Function(Size box) onDragEnd;

  @override
  Widget build(BuildContext context) {
    if (!attached) {
      return const Center(
        child: Text('Open a chat to use the cloud browser.'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final image = frame;
        if (image == null) {
          // No page yet: the placeholder (error / retry / timeout) must stay
          // tappable even while the agent holds control.
          return Container(
            color: Aether.bg,
            alignment: Alignment.center,
            child: _placeholder(),
          );
        }
        return IgnorePointer(
          ignoring: !takeover,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => onTap(details.localPosition, box),
            onPanStart: (_) => onDragStart(),
            onPanUpdate: (details) => onDragUpdate(details.delta),
            onPanEnd: (_) => onDragEnd(box),
            child: Container(
              color: Aether.bg,
              alignment: Alignment.center,
              child: _FrameImage(frame: image),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder() {
    final failure = error;
    if (failure != null) {
      return Padding(
        key: const ValueKey('browser-error'),
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 28, color: Aether.textMuted),
            const SizedBox(height: 10),
            const Text(
              'Browser unavailable',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              failure.message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
            const SizedBox(height: 2),
            Text(
              failure.code,
              style: TextStyle(fontSize: 11, color: Aether.textFaint),
            ),
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('browser-retry'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Text(
            waitExpired
                ? "The agent hasn't opened a page in this chat yet."
                : live
                    ? 'Waiting for the live browser…'
                    : 'The cloud browser is starting…',
            key: const ValueKey('browser-status'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
        ),
        if (waitExpired)
          TextButton(
            key: const ValueKey('browser-retry'),
            onPressed: onRetry,
            child: const Text('Check again'),
          ),
      ],
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

class _ControlChip extends StatelessWidget {
  const _ControlChip({
    super.key,
    required this.label,
    required this.action,
    required this.onPressed,
  });

  final String label;
  final String action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Aether.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onPressed,
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}
