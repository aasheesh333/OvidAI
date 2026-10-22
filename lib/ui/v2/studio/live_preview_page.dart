import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// Formats the time left before a preview expires.
///
/// Hours are shown for long previews, seconds only in the final hour so the
/// countdown visibly moves without shouting. A positive duration under one
/// second reads as "1s" instead of "0s" so a live preview never shows a zero
/// that is not yet expired.
String formatPreviewCountdown(Duration remaining) {
  if (remaining <= Duration.zero) return 'Expired';
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  final seconds = remaining.inSeconds % 60;
  if (hours > 0) {
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
  if (seconds == 0) return '1s';
  return '${seconds}s';
}

/// The spoken form of [formatPreviewCountdown].
///
/// Screen readers should hear "4 minutes 12 seconds", not "4m 12s", and the
/// countdown should never announce a bare "0s" before the screen expires.
String formatPreviewCountdownSpoken(Duration remaining) {
  if (remaining <= Duration.zero) return 'no time left';
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  final seconds = remaining.inSeconds % 60;
  final parts = <String>[];
  if (hours > 0) {
    parts.add('$hours ${hours == 1 ? 'hour' : 'hours'}');
  }
  if (minutes > 0) {
    parts.add('$minutes ${minutes == 1 ? 'minute' : 'minutes'}');
  }
  if (hours == 0 && seconds > 0) {
    parts.add('$seconds ${seconds == 1 ? 'second' : 'seconds'}');
  }
  return parts.isEmpty ? 'less than a second' : parts.join(' ');
}

/// What the live preview is doing right now.
enum V2PreviewStatus {
  /// A preview is being allocated; no frame has arrived yet.
  connecting,

  /// A real frame is on screen.
  live,

  /// The stream stopped; the last frame stays dimmed with a reconnect action.
  lost,

  /// The preview could not start, with a reason.
  error,

  /// The session deadline passed or the server ended it.
  expired,

  /// No frame source exists for this workspace.
  unavailable;

  /// Compatibility aliases for the earlier three-state contract. New code
  /// should use the names above; these keep existing hosts compiling while
  /// they move to the explicit states.
  @Deprecated('Use V2PreviewStatus.connecting')
  static V2PreviewStatus get loading => connecting;

  @Deprecated('Use V2PreviewStatus.live')
  static V2PreviewStatus get content => live;

  @Deprecated('Use V2PreviewStatus.unavailable')
  static V2PreviewStatus get empty => unavailable;
}

/// Everything the live preview needs to render.
///
/// The frame is the only page-shaped surface: there is no synthesized site
/// copy and no sample content. A host either supplies a real [ImageProvider]
/// and a real [url], or the screen says plainly that no preview source exists.
@immutable
class V2LivePreviewData {
  const V2LivePreviewData({
    this.status = V2PreviewStatus.unavailable,
    this.siteName = '',
    this.url = '',
    this.frame,
    this.expiresAt,
    this.errorMessage,
    this.unavailableReason = '',
    this.frameAspectRatio = 16 / 10,
  });

  final V2PreviewStatus status;

  /// The workspace or project the preview belongs to. Used only in honest
  /// empty/expired copy; never as a substitute for a frame.
  final String siteName;

  /// The real preview URL. Also the source of the origin shown in the status
  /// pill and the exact string announced for the frame.
  final String url;

  /// Real pixels from the sandbox. Null means there is nothing to show, not
  /// that a blank page should be painted.
  final ImageProvider? frame;

  /// When the preview URL stops working. The countdown is derived from this
  /// deadline; when it reaches zero the screen moves to [V2PreviewStatus.expired].
  final DateTime? expiresAt;

  /// The real failure reason for the error state or the lost-stream line.
  final String? errorMessage;

  /// Why no frame source exists, supplied by the wiring layer. The screen
  /// falls back to a plain sentence naming [siteName] when this is empty.
  final String unavailableReason;

  /// The preview viewport's width / height ratio. A host may pass the real
  /// sandbox viewport; the default is a desktop page.
  final double frameAspectRatio;

  /// The host shown in the status pill, parsed from the real URL.
  String get origin {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
    if (uri == null || uri.host.isEmpty) return raw;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.host}$port';
  }

  /// Never let malformed wiring data break the frame layout.
  double get safeFrameAspectRatio =>
      frameAspectRatio.isFinite && frameAspectRatio > 0
      ? frameAspectRatio
      : 16 / 10;
}

/// A viewer for the app running in the workspace: one real frame, one status
/// pill over it, and compact secondary controls below it.
///
/// Every control disappears when its handler is absent. There is no synthetic
/// page, no fake address bar, and no "Online" badge over an empty box: without
/// a frame the screen is honest about why it has nothing to show.
class V2LivePreviewPage extends StatefulWidget {
  const V2LivePreviewPage({
    super.key,
    required this.data,
    this.onReload,
    this.onOpenInBrowser,
    this.onCopyUrl,
    this.onStop,
    this.onCancel,
    this.onReconnect,
    this.onStart,
    this.onRetry,
    @Deprecated('Use onCopyUrl') this.onShareLink,
  });

  final V2LivePreviewData data;

  /// Reload the preview (the header action while live).
  final VoidCallback? onReload;

  /// Open the real preview URL in the system browser.
  final VoidCallback? onOpenInBrowser;

  /// Copy the real preview URL.
  final VoidCallback? onCopyUrl;

  /// Stop the preview session.
  final VoidCallback? onStop;

  /// Abort the connection attempt.
  final VoidCallback? onCancel;

  /// Reconnect after the stream was lost.
  final VoidCallback? onReconnect;

  /// Start a new preview session after an empty or expired preview.
  final VoidCallback? onStart;

  /// Retry a failed preview or a failed start.
  final VoidCallback? onRetry;

  /// Old name for [onCopyUrl]. Kept so existing hosts compile while they move
  /// to the explicit copy action.
  @Deprecated('Use onCopyUrl')
  final VoidCallback? onShareLink;

  @override
  State<V2LivePreviewPage> createState() => _V2LivePreviewPageState();
}

class _V2LivePreviewPageState extends State<V2LivePreviewPage>
    with WidgetsBindingObserver {
  Timer? _timer;
  Duration _remaining = Duration.zero;
  bool _expired = false;

  VoidCallback? get _reload => widget.onReload;
  VoidCallback? get _copyUrl => widget.onCopyUrl ?? widget.onShareLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncCountdown();
  }

  @override
  void didUpdateWidget(V2LivePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldData = oldWidget.data;
    final data = widget.data;
    if (oldData.expiresAt != data.expiresAt ||
        oldData.status != data.status ||
        (oldData.frame == null) != (data.frame == null)) {
      _syncCountdown();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.resumed:
        if (!mounted) return;
        setState(_syncCountdown);
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-anchor the countdown to the real deadline. This runs on first build,
  /// when the data changes, and when the app comes back to the foreground.
  void _syncCountdown() {
    _timer?.cancel();
    _timer = null;

    final deadline = widget.data.expiresAt;
    final status = widget.data.status;
    final needsClock =
        deadline != null &&
        switch (status) {
          V2PreviewStatus.connecting => true,
          V2PreviewStatus.live => widget.data.frame != null,
          V2PreviewStatus.lost => true,
          V2PreviewStatus.error ||
          V2PreviewStatus.expired ||
          V2PreviewStatus.unavailable => false,
        };

    final left = deadline?.difference(DateTime.now());
    _remaining = (left == null || left.isNegative) ? Duration.zero : left;
    _expired =
        status == V2PreviewStatus.expired ||
        (needsClock && _remaining <= Duration.zero);

    if (!needsClock || _expired) return;
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void _tick(Timer timer) {
    if (!mounted) return;
    // Never show more time than the real deadline allows: if the wall clock
    // has moved further than one tick (a late frame, a long pause, a clock
    // adjustment) the deadline wins. The one-second decrement keeps the
    // countdown moving when the clock has not advanced, as in widget tests.
    final byClock = widget.data.expiresAt?.difference(DateTime.now());
    var next = _remaining - const Duration(seconds: 1);
    if (byClock != null && byClock < next) next = byClock;
    if (next <= Duration.zero) {
      timer.cancel();
      _timer = null;
      setState(() {
        _remaining = Duration.zero;
        _expired = true;
      });
      return;
    }
    setState(() => _remaining = next);
  }

  V2PreviewStatus get _status {
    final data = widget.data;
    switch (data.status) {
      case V2PreviewStatus.error:
        return V2PreviewStatus.error;
      case V2PreviewStatus.expired:
        return V2PreviewStatus.expired;
      case V2PreviewStatus.unavailable:
        return V2PreviewStatus.unavailable;
      case V2PreviewStatus.connecting:
        return _expired ? V2PreviewStatus.expired : V2PreviewStatus.connecting;
      case V2PreviewStatus.lost:
        return _expired ? V2PreviewStatus.expired : V2PreviewStatus.lost;
      case V2PreviewStatus.live:
        if (_expired) return V2PreviewStatus.expired;
        if (data.frame == null) return V2PreviewStatus.unavailable;
        return V2PreviewStatus.live;
    }
  }

  Duration? get _timeLeft =>
      widget.data.expiresAt == null || _remaining <= Duration.zero
      ? null
      : _remaining;

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return OScreen(
      title: 'Live preview',
      padding: false,
      actions: [
        if (status == V2PreviewStatus.live && _reload != null)
          OIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: 'Reload preview',
            tooltip: 'Reload',
            onPressed: _reload,
          ),
      ],
      child: switch (status) {
        V2PreviewStatus.connecting => _buildConnecting(context),
        V2PreviewStatus.live => _buildLive(context),
        V2PreviewStatus.lost => _buildLost(context),
        V2PreviewStatus.error => _buildError(),
        V2PreviewStatus.expired => _buildExpired(),
        V2PreviewStatus.unavailable => _buildUnavailable(),
      },
    );
  }

  Widget _buildLive(BuildContext context) {
    final data = widget.data;
    final r = OResponsive.of(context);
    final actions = _actions();
    return Padding(
      padding: EdgeInsets.fromLTRB(r.gutter, OSpace.s, r.gutter, OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _FrameArea(
              aspectRatio: data.safeFrameAspectRatio,
              child: _LiveFrame(
                frame: data.frame!,
                url: data.url,
                origin: data.origin,
                timeLeft: _timeLeft,
                semanticLabel: _statusSemantics('Live'),
                onTryAgain: widget.onRetry,
              ),
            ),
          ),
          if (actions != null) ...[const SizedBox(height: OSpace.xs), actions],
        ],
      ),
    );
  }

  Widget _buildLost(BuildContext context) {
    final data = widget.data;
    final r = OResponsive.of(context);
    final reconnect = widget.onReconnect ?? widget.onReload;
    final actions = _actions(reconnect: reconnect);
    final suppliedReason = data.errorMessage?.trim();
    final reason = suppliedReason == null || suppliedReason.isEmpty
        ? 'The preview stream stopped.'
        : suppliedReason;
    return Padding(
      padding: EdgeInsets.fromLTRB(r.gutter, OSpace.s, r.gutter, OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _FrameArea(
              aspectRatio: data.safeFrameAspectRatio,
              child: _LostFrame(
                frame: data.frame,
                url: data.url,
                origin: data.origin,
                timeLeft: _timeLeft,
                semanticLabel: _statusSemantics('Lost'),
              ),
            ),
          ),
          // The reason and the reconnect action live below the frame, not on
          // top of it: a short landscape frame cannot hold a notice card and
          // its button without covering the status pill.
          const SizedBox(height: OSpace.s),
          Text(
            reason,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: OType.caption.copyWith(color: OColors.of(context).textMuted),
          ),
          if (actions != null) ...[const SizedBox(height: OSpace.xs), actions],
        ],
      ),
    );
  }

  Widget _buildConnecting(BuildContext context) {
    final data = widget.data;
    final r = OResponsive.of(context);
    final cancel = widget.onCancel ?? widget.onStop;
    return Padding(
      padding: EdgeInsets.fromLTRB(r.gutter, OSpace.s, r.gutter, OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _FrameArea(
              aspectRatio: data.safeFrameAspectRatio,
              child: _ConnectingFrame(
                origin: data.origin,
                timeLeft: _timeLeft,
                semanticLabel: _statusSemantics('Connecting'),
              ),
            ),
          ),
          if (cancel != null) ...[
            const SizedBox(height: OSpace.xs),
            OTextAction(
              label: 'Cancel',
              icon: Icons.close_rounded,
              onPressed: cancel,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildError() {
    final reason = widget.data.errorMessage?.trim();
    return _stateView(
      icon: Icons.error_outline_rounded,
      title: 'Preview failed',
      message: reason == null || reason.isEmpty
          ? 'The preview could not start.'
          : reason,
      action: widget.onRetry == null
          ? null
          : OButton(
              label: 'Try again',
              icon: Icons.refresh_rounded,
              onPressed: widget.onRetry,
            ),
    );
  }

  Widget _buildExpired() {
    final data = widget.data;
    final site = data.siteName.trim();
    final reason = data.errorMessage?.trim();
    return _stateView(
      icon: Icons.timer_off_outlined,
      title: 'Preview ended',
      message: reason != null && reason.isNotEmpty
          ? reason
          : site.isNotEmpty
          ? 'The preview for $site ended.'
          : 'This preview session ended.',
      action: widget.onStart == null
          ? null
          : OButton(
              label: 'Start preview',
              icon: Icons.play_arrow_rounded,
              onPressed: widget.onStart,
            ),
    );
  }

  Widget _buildUnavailable() {
    final data = widget.data;
    final site = data.siteName.trim();
    final reason = data.unavailableReason.trim();
    final Widget? action;
    if (widget.onStart != null) {
      action = OButton(
        label: 'Start preview',
        icon: Icons.play_arrow_rounded,
        onPressed: widget.onStart,
      );
    } else if (widget.onRetry != null) {
      action = OButton(
        label: 'Try again',
        icon: Icons.refresh_rounded,
        variant: OButtonVariant.secondary,
        onPressed: widget.onRetry,
      );
    } else {
      action = null;
    }
    return _stateView(
      icon: Icons.visibility_off_outlined,
      title: 'No preview',
      message: reason.isNotEmpty
          ? reason
          : site.isNotEmpty
          ? 'No preview source for $site.'
          : 'No preview source is connected.',
      action: action,
    );
  }

  /// The shared empty/error state, with its action pinned below the scroll
  /// area on a short landscape body. Otherwise a tall message can push the
  /// only recovery action below the fold.
  Widget _stateView({
    required IconData icon,
    required String title,
    required String message,
    required Widget? action,
  }) {
    Widget state({Widget? withAction}) => OEmptyState(
      icon: icon,
      title: title,
      message: message,
      compact: true,
      action: withAction,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final short =
            constraints.hasBoundedHeight && constraints.maxHeight < 360;
        if (!short || action == null) {
          return state(withAction: action);
        }
        return Column(
          children: [
            Expanded(child: state()),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                0,
                OSpace.l,
                OSpace.l,
              ),
              child: Center(child: action),
            ),
          ],
        );
      },
    );
  }

  Widget? _actions({VoidCallback? reconnect}) {
    final url = widget.data.url.trim();
    final copy = _copyUrl;
    final open = widget.onOpenInBrowser;
    final children = <Widget>[
      if (reconnect != null)
        OButton(
          label: 'Reconnect',
          icon: Icons.refresh_rounded,
          variant: OButtonVariant.secondary,
          onPressed: reconnect,
        ),
      if (url.isNotEmpty && copy != null)
        OTextAction(
          label: 'Copy URL',
          icon: Icons.copy_rounded,
          onPressed: copy,
        ),
      if (url.isNotEmpty && open != null)
        OTextAction(
          label: 'Open in browser',
          icon: Icons.open_in_new_rounded,
          onPressed: open,
        ),
      if (widget.onStop != null)
        OTextAction(
          label: 'Stop preview',
          icon: Icons.stop_circle_outlined,
          onPressed: widget.onStop,
        ),
    ];
    if (children.isEmpty) return null;
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  /// Speak the visible status pill: state, real origin, real time left.
  String _statusSemantics(String state) {
    final data = widget.data;
    final parts = <String>[state];
    if (data.origin.isNotEmpty) parts.add(data.origin);
    final left = _timeLeft;
    if (left != null) {
      parts.add('${formatPreviewCountdownSpoken(left)} left');
    }
    return '${parts.join(', ')}.';
  }
}

/// The frame's footprint: the largest box with the real viewport ratio that
/// fits under the header. A wide or short window letterboxes instead of
/// stretching, and the ratio never changes with the window.
class _FrameArea extends StatelessWidget {
  const _FrameArea({required this.aspectRatio, required this.child});

  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ratio = aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : 16 / 10;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return AspectRatio(aspectRatio: ratio, child: child);
        }
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        if (maxWidth <= 0 || maxHeight <= 0) return const SizedBox.shrink();
        var width = maxWidth;
        var height = width / ratio;
        if (height > maxHeight) {
          height = maxHeight;
          width = height * ratio;
        }
        return Center(
          child: SizedBox(width: width, height: height, child: child),
        );
      },
    );
  }
}

/// A framed real surface with no page chrome: no address bar, no fake title
/// bar, no controls that do not map to a handler.
class _FrameShell extends StatelessWidget {
  const _FrameShell({this.frameKey, required this.child});

  final Key? frameKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: frameKey,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.xl),
        border: Border.all(color: c.hairlineStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A live frame plus its status pill.
///
/// The pill is only shown after the first decoded frame. Until then the frame
/// is a skeleton, never a blank surface that looks live.
class _LiveFrame extends StatefulWidget {
  const _LiveFrame({
    required this.frame,
    required this.url,
    required this.origin,
    required this.timeLeft,
    required this.semanticLabel,
    this.onTryAgain,
  });

  final ImageProvider frame;
  final String url;
  final String origin;
  final Duration? timeLeft;
  final String semanticLabel;
  final VoidCallback? onTryAgain;

  @override
  State<_LiveFrame> createState() => _LiveFrameState();
}

class _LiveFrameState extends State<_LiveFrame> {
  bool _ready = false;
  bool _failed = false;
  bool _failureQueued = false;
  bool? _readyQueued;
  int _attempt = 0;

  @override
  void didUpdateWidget(_LiveFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame != widget.frame) {
      _ready = false;
      _failed = false;
      _failureQueued = false;
      _readyQueued = null;
      _attempt++;
    }
  }

  void _queueReady(bool ready) {
    if (!mounted || _ready == ready || _readyQueued == ready) return;
    final attempt = _attempt;
    _readyQueued = ready;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || attempt != _attempt) return;
      _readyQueued = null;
      if (_ready != ready) setState(() => _ready = ready);
    });
  }

  void _queueFailure() {
    if (!mounted || _failed || _failureQueued) return;
    final attempt = _attempt;
    _failureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _failed = true;
        _failureQueued = false;
      });
    });
  }

  void _tryAgain() {
    unawaited(widget.frame.evict());
    widget.onTryAgain?.call();
    setState(() {
      _failed = false;
      _failureQueued = false;
      _ready = false;
      _readyQueued = null;
      _attempt++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return _FrameShell(
        frameKey: const Key('preview-frame'),
        child: _FrameError(onTryAgain: _tryAgain),
      );
    }

    final frameLabel = widget.url.isEmpty
        ? 'Live preview'
        : 'Live preview of ${widget.url}';
    return _FrameShell(
      frameKey: const Key('preview-frame'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            image: true,
            label: _ready ? frameLabel : 'Loading preview',
            child: Image(
              key: ValueKey<int>(_attempt),
              image: widget.frame,
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              excludeFromSemantics: true,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                final ready = wasSynchronouslyLoaded || frame != null;
                _queueReady(ready);
                return ready ? child : const _FrameSkeleton();
              },
              errorBuilder: (context, error, stackTrace) {
                _queueFailure();
                return const ColoredBox(color: Colors.transparent);
              },
            ),
          ),
          if (_ready)
            Positioned(
              left: OSpace.s,
              top: OSpace.s,
              right: OSpace.s,
              child: Align(
                alignment: Alignment.topLeft,
                child: _FrameStatus(
                  status: V2PreviewStatus.live,
                  origin: widget.origin,
                  timeLeft: widget.timeLeft,
                  semanticLabel: widget.semanticLabel,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A frame that is still being allocated. The skeleton is the surface; the
/// pill is wording, not an invented page.
class _ConnectingFrame extends StatelessWidget {
  const _ConnectingFrame({
    required this.origin,
    required this.timeLeft,
    required this.semanticLabel,
  });

  final String origin;
  final Duration? timeLeft;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _FrameShell(
      frameKey: const Key('preview-connecting-frame'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const _FrameSkeleton(),
          Positioned(
            left: OSpace.s,
            top: OSpace.s,
            right: OSpace.s,
            child: Align(
              alignment: Alignment.topLeft,
              child: _FrameStatus(
                status: V2PreviewStatus.connecting,
                origin: origin,
                timeLeft: timeLeft,
                semanticLabel: semanticLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last frame, dimmed, with the lost status pill over it.
///
/// The reason and the reconnect action are rendered below the frame by the
/// page: a short landscape frame cannot hold a notice card without covering
/// the pill. If the old image cannot be decoded the shell's neutral surface
/// shows through, so there is never a blank rectangle that looks like a page.
class _LostFrame extends StatelessWidget {
  const _LostFrame({
    required this.frame,
    required this.url,
    required this.origin,
    required this.timeLeft,
    required this.semanticLabel,
  });

  final ImageProvider? frame;
  final String url;
  final String origin;
  final Duration? timeLeft;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final image = frame;
    final lastFrameLabel = url.isEmpty
        ? 'Last preview frame'
        : 'Last preview frame of $url';
    return _FrameShell(
      frameKey: const Key('preview-frame'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Opacity(
              opacity: 0.35,
              child: Semantics(
                image: true,
                label: lastFrameLabel,
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            )
          else
            ColoredBox(color: c.surfaceAlt),
          ColoredBox(color: c.scrim.withValues(alpha: 0.55)),
          Positioned(
            left: OSpace.s,
            top: OSpace.s,
            right: OSpace.s,
            child: Align(
              alignment: Alignment.topLeft,
              child: _FrameStatus(
                status: V2PreviewStatus.lost,
                origin: origin,
                timeLeft: timeLeft,
                semanticLabel: semanticLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single status pill over the frame: real status word, real origin and a
/// live time left.
///
/// The header line is a [Wrap], so at large text scales the origin moves to
/// its own line instead of overflowing the pill; the status word is the only
/// child that ellipsizes, and only when even it cannot fit. The countdown
/// always keeps its own line.
class _FrameStatus extends StatelessWidget {
  const _FrameStatus({
    required this.status,
    required this.origin,
    required this.timeLeft,
    required this.semanticLabel,
  });

  final V2PreviewStatus status;
  final String origin;
  final Duration? timeLeft;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final caption = OType.caption.copyWith(color: c.textMuted);
    final statusWord = switch (status) {
      V2PreviewStatus.connecting => 'Connecting',
      V2PreviewStatus.lost => 'Lost',
      _ => 'Live',
    };
    final dotColor = switch (status) {
      V2PreviewStatus.connecting => c.textFaint,
      V2PreviewStatus.lost => c.warn,
      _ => c.text,
    };
    final countdown = timeLeft == null
        ? null
        : formatPreviewCountdown(timeLeft!);
    return Semantics(
      key: const Key('preview-status'),
      container: true,
      excludeSemantics: true,
      label: semanticLabel,
      child: Container(
        constraints: const BoxConstraints(minHeight: OSpace.xl),
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.pillPad,
          vertical: OSpace.xxs,
        ),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.pill),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: OSpace.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: OSpace.iconGap,
                      height: OSpace.iconGap,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: OSpace.iconGap),
                    Flexible(
                      child: Text(
                        statusWord,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (origin.isNotEmpty)
                  Text(
                    origin,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: caption,
                  ),
              ],
            ),
            if (countdown != null)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  countdown,
                  maxLines: 1,
                  style: OType.caption.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FrameSkeleton extends StatelessWidget {
  const _FrameSkeleton();

  @override
  Widget build(BuildContext context) {
    return const OSkeleton(height: double.infinity, radius: ORadius.xl);
  }
}

/// Shown when the frame provider cannot decode and no new frame has arrived.
/// It is explicitly an error, never a blank rectangle that looks loaded.
class _FrameError extends StatelessWidget {
  const _FrameError({required this.onTryAgain});

  final VoidCallback onTryAgain;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      key: const Key('preview-frame-error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 32, color: c.danger),
            const SizedBox(height: OSpace.s),
            Text(
              'Frame failed',
              textAlign: TextAlign.center,
              style: OType.body.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.xs),
            Text(
              'The preview frame could not be shown.',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              label: 'Try again',
              variant: OButtonVariant.secondary,
              onPressed: onTryAgain,
            ),
          ],
        ),
      ),
    );
  }
}
