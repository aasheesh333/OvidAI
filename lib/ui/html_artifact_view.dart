import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/diag.dart';
import '../core/html_artifact.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Inline chat artifact host. The native view is deliberately independent of
/// browser tabs, auth controllers and plugin UI. Removing it destroys the
/// document (source/collapse/background/session switch); reopening starts fresh.
class HtmlArtifactView extends StatefulWidget {
  final HtmlArtifact? artifact;
  final String sessionId;
  final _ArtifactExecution? _execution;
  final bool _fullscreen;

  const HtmlArtifactView({
    super.key,
    required this.artifact,
    required this.sessionId,
  }) : _execution = null,
       _fullscreen = false;

  const HtmlArtifactView._fullscreen(
    this._execution, {
    super.key,
    required this.artifact,
    required this.sessionId,
  }) : _fullscreen = true;

  @override
  State<HtmlArtifactView> createState() => _HtmlArtifactViewState();
}

// Serializes native stop/start acknowledgements across inline/fullscreen and
// rapid lifecycle changes. A replacement never executes beside its predecessor.
class _ArtifactExecution {
  Future<void> _pending = Future.value();

  Future<void> run(Future<void> Function() operation) {
    final next = _pending.then((_) => operation());
    _pending = next.catchError((Object _) {});
    return next;
  }
}

class _HtmlArtifactViewState extends State<HtmlArtifactView>
    with WidgetsBindingObserver {
  bool _source = false;
  bool _expanded = false;
  bool _collapsed = false;
  bool _foreground = true;
  int? _viewId;
  int _generation = 0;
  String? _failure;
  late final _ArtifactExecution _execution;
  MaterialPageRoute<void>? _fullscreenRoute;
  final _fullscreenKey = GlobalKey<_HtmlArtifactViewState>();
  bool _exiting = false;
  bool _canPop = false;
  bool _tickerEnabled = true;

  @override
  void initState() {
    super.initState();
    _execution = widget._execution ?? _ArtifactExecution();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(HtmlArtifactView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artifact?.id != widget.artifact?.id ||
        oldWidget.sessionId != widget.sessionId) {
      unawaited(_stop());
      _removeFullscreen();
      _generation++;
      _failure = null;
      _source = _expanded = _collapsed = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (!enabled && _tickerEnabled) {
      unawaited(_stop());
      _generation++;
    }
    _tickerEnabled = enabled;
  }

  Future<void> _stop() {
    final id = _viewId;
    _viewId = null;
    if (id == null) return _execution.run(() async {});
    final channel = MethodChannel('ovid/html-artifact/$id');
    channel.setMethodCallHandler(null);
    return _execution.run(() async {
      try {
        await channel.invokeMethod<void>('disposeDocument');
      } on PlatformException catch (_) {
        // AndroidView disposal still destroys the native view.
      } on MissingPluginException catch (_) {
        // Native exception details may contain user source; log only a safe tag.
        Diag.swallow(
          'html_artifact_view.stop',
          'Artifact disposal unavailable.',
        );
      }
    });
  }

  void _refresh({bool retry = false}) {
    unawaited(_stop());
    setState(() {
      _generation++;
      if (retry) _failure = null;
    });
  }

  void _loadFailed(Object? details, int id, int generation) {
    if (!mounted || _viewId != id || generation != _generation) return;
    final code = details is Map ? details['code'] : null;
    // Never display a native URL/description: a data URL contains user source.
    _failure = switch (code) {
      'renderer_gone' => 'Artifact renderer stopped.',
      'unsupported_renderer' =>
        'Artifact preview is unavailable on this device.',
      _ => 'Artifact preview could not be loaded.',
    };
    _refresh();
  }

  void _created(int id, int generation) {
    final channel = MethodChannel('ovid/html-artifact/$id');
    if (!mounted ||
        generation != _generation ||
        _expanded ||
        _collapsed ||
        _source ||
        !_foreground ||
        !_tickerEnabled ||
        _exiting ||
        _failure != null) {
      unawaited(
        _execution.run(() async {
          try {
            await channel.invokeMethod<void>('disposeDocument');
          } on PlatformException catch (_) {
          } on MissingPluginException catch (_) {
            // Native exception details may contain user source; log only a safe tag.
            Diag.swallow(
              'html_artifact_view.dispose_stale',
              'Artifact disposal unavailable.',
            );
          }
        }),
      );
      return;
    }
    _viewId = id;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'loadError') {
        _loadFailed(call.arguments, id, generation);
      }
    });
    unawaited(
      _execution.run(() async {
        if (!mounted || _viewId != id || generation != _generation) return;
        try {
          final error = await channel.invokeMethod<Object?>('startDocument');
          if (error != null) _loadFailed(error, id, generation);
        } catch (_) {
          _loadFailed(null, id, generation);
        }
      }),
    );
  }

  void _removeFullscreen() {
    final fullscreen = _fullscreenKey.currentState;
    if (fullscreen != null) {
      fullscreen._generation++;
      unawaited(fullscreen._stop());
    }
    final route = _fullscreenRoute;
    _fullscreenRoute = null;
    if (route == null) return;
    // didUpdateWidget/dispose can run while the navigator is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  Future<void> _expand() async {
    if (_expanded) return;
    final artifact = widget.artifact;
    final session = widget.sessionId;
    final generation = _generation;
    final origin = ModalRoute.of(context);
    setState(() => _expanded = true);
    await _stop();
    if (!mounted ||
        artifact != widget.artifact ||
        session != widget.sessionId) {
      return;
    }
    if (generation != _generation ||
        _collapsed ||
        _source ||
        !_foreground ||
        !_tickerEnabled ||
        origin != ModalRoute.of(context) ||
        (origin != null && !origin.isCurrent)) {
      setState(() {
        _expanded = false;
        _generation++;
      });
      return;
    }
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => HtmlArtifactView._fullscreen(
        _execution,
        key: _fullscreenKey,
        artifact: artifact,
        sessionId: session,
      ),
    );
    _fullscreenRoute = route;
    unawaited(Navigator.of(context).push(route));
    await route.completed; // Wait through reverse animation and child disposal.
    if (!mounted || _fullscreenRoute != route) return;
    _fullscreenRoute = null;
    setState(() {
      _expanded = false;
      _generation++;
    });
  }

  Future<void> _exitFullscreen() async {
    if (_exiting) return;
    _exiting = true;
    await _stop();
    if (!mounted) return;
    setState(() {
      _canPop = true;
      _collapsed = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      // A paused Flutter engine does not paint setState. Stop native execution
      // immediately, without waiting for another frame to unmount AndroidView.
      unawaited(_stop());
      _generation++;
    }
    if (mounted) {
      setState(() {
        if (foreground && !_foreground) _generation++;
        _foreground = foreground;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_stop());
    _removeFullscreen();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _control({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    // The shared ghost label button is fixed at 44dp. At enlarged text sizes
    // let the label wrap and the action grow instead of truncating its name.
    if (MediaQuery.textScalerOf(context).scale(14) <= 14) {
      return AetherGhostButton(
        label: label,
        tooltip: label,
        icon: icon,
        onPressed: onPressed,
      );
    }
    return Tooltip(
      message: label,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Aether.textMuted,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(label)),
          ],
        ),
      ),
    );
  }

  /// Chrome heading: the artifact title with the sandbox guarantee folded
  /// into one quiet status caption (the old bordered pill is gone).
  Widget _chromeHeading(HtmlArtifact artifact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(artifact.title, style: AetherType.title),
        const SizedBox(height: 2),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 11, color: Aether.textFaint),
            const SizedBox(width: 4),
            // Flexible keeps the caption inside the chrome at enlarged text
            // sizes: it wraps to a second line instead of pushing the row
            // past the card edge.
            Flexible(
              child: Text(
                'OFFLINE SANDBOX',
                style: AetherType.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: .8,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// The single chrome action group: collapse (inline only), the
  /// source/preview toggle and expand/exit. Source and expand hide while the
  /// inline card is collapsed, leaving title + collapse as the whole chrome.
  Widget _chromeActions() {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        if (!widget._fullscreen)
          IconButton(
            tooltip: _collapsed ? 'Open artifact' : 'Collapse artifact',
            icon: Icon(
              _collapsed ? Icons.expand_more : Icons.expand_less,
              size: 20,
              color: Aether.textMuted,
            ),
            onPressed: () {
              _collapsed = !_collapsed;
              _refresh();
            },
          ),
        if (widget._fullscreen || !_collapsed) ...[
          _control(
            label: _source ? 'Show preview' : 'View source',
            icon: _source ? Icons.preview_outlined : Icons.code,
            onPressed: () {
              _source = !_source;
              _refresh();
            },
          ),
          _control(
            label: widget._fullscreen ? 'Exit fullscreen' : 'Expand preview',
            icon: widget._fullscreen
                ? Icons.fullscreen_exit
                : Icons.fullscreen,
            onPressed: _expanded
                ? null
                : widget._fullscreen
                ? _exitFullscreen
                : _expand,
          ),
        ],
      ],
    );
  }

  /// Rounded hairline frame shared by the live preview and the source sheet
  /// so the content region keeps one shape in every state. The native view
  /// is deliberately not clipped: platform-view clipping costs a composition
  /// pass and its rectangular surface already meets the border cleanly.
  Widget _framed({required Widget child, Color? background, bool clip = false}) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.hairline),
      ),
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      child: child,
    );
  }

  Widget _preview(HtmlArtifact artifact, bool supported, int generation) {
    if (_source) {
      return _framed(
        background: Aether.codeBg,
        clip: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            '${artifact.html}\n\n/* CSS */\n${artifact.css}\n\n// JavaScript\n${artifact.javascript}',
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
          ),
        ),
      );
    }
    final failure = _failure;
    if (failure != null) {
      return _PreviewPlaceholder(
        icon: Icons.error_outline,
        title: failure,
        live: true,
        action: AetherGhostButton(
          label: 'Retry',
          icon: Icons.refresh,
          onPressed: () => _refresh(retry: true),
        ),
      );
    }
    if (!supported) {
      return const _PreviewPlaceholder(
        icon: Icons.phone_android_outlined,
        title: 'Interactive preview requires Android.',
        message: 'Use View source to inspect this saved artifact.',
      );
    }
    if (!_foreground || !_tickerEnabled || _expanded || _collapsed) {
      return _PreviewPlaceholder(
        icon: _expanded ? Icons.fullscreen : Icons.pause_circle_outline,
        title: _expanded ? 'Preview open in fullscreen.' : 'Preview paused.',
      );
    }
    return _framed(
      child: AndroidView(
        key: ValueKey('${widget.sessionId}:${artifact.id}:$generation'),
        viewType: 'ovid/html-artifact',
        creationParams: {'document': artifact.sandboxDocument},
        creationParamsCodec: const StandardMessageCodec(),
        layoutDirection: TextDirection.ltr,
        onPlatformViewCreated: (id) => _created(id, generation),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final artifact = widget.artifact;
    if (artifact == null || artifact.sessionId != widget.sessionId) {
      return const Text(
        'Artifact unavailable: missing, invalid, or owned by another session.',
      );
    }
    final supported =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final generation = _generation;
    final viewport = MediaQuery.sizeOf(context).height;
    final height = math.max(
      160.0,
      math.min(artifact.height.toDouble(), math.max(160.0, viewport * .75)),
    );
    if (widget._fullscreen) {
      return PopScope<void>(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_exitFullscreen());
        },
        child: Scaffold(
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: OverflowBar(
                    alignment: MainAxisAlignment.spaceBetween,
                    overflowAlignment: OverflowBarAlignment.start,
                    spacing: 12,
                    overflowSpacing: 8,
                    children: [
                      _chromeHeading(artifact),
                      _chromeActions(),
                    ],
                  ),
                ),
                Divider(height: 1, thickness: 1, color: Aether.hairline),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _preview(artifact, supported, generation),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Inline: Aether card host. One chrome row in the card header; the body
    // below it is collapsible.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AetherCard(
        padding: const EdgeInsets.all(12),
        title: _chromeHeading(artifact),
        trailing: _chromeActions(),
        child: _collapsed
            ? const SizedBox.shrink()
            : SizedBox(
                height: height,
                child: _preview(artifact, supported, generation),
              ),
      ),
    );
  }
}

/// The one empty-state recipe for every non-running preview: load failure,
/// unsupported platform, background pause and fullscreen relocation share a
/// soft framed surface, a quiet circled icon and a centered title. [action]
/// carries the single recovery affordance (retry) where one exists.
class _PreviewPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool live;

  const _PreviewPlaceholder({
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.live = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.hairline),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AetherSpacing.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  shape: BoxShape.circle,
                  border: Border.all(color: Aether.hairline),
                ),
                child: Icon(icon, size: 20, color: Aether.textFaint),
              ),
              const SizedBox(height: 10),
              Semantics(
                liveRegion: live,
                child: Text(
                  title,
                  style: AetherType.title,
                  textAlign: TextAlign.center,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 4),
                Text(
                  message!,
                  style: AetherType.caption,
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 8),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
