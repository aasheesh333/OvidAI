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
  String? _copiedSection;
  Timer? _copyFeedbackTimer;

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

  Future<void> _copySource(String section, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    _copyFeedbackTimer?.cancel();
    setState(() => _copiedSection = section);
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedSection = null);
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
    _copyFeedbackTimer?.cancel();
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

  Widget _sourceSection({
    required String label,
    required String value,
  }) {
    final copied = _copiedSection == label;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Aether.surface.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.textMuted.withValues(alpha: .22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .5,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: copied ? '$label copied' : 'Copy $label',
                  icon: Icon(copied ? Icons.check : Icons.copy, size: 18),
                  onPressed: () => _copySource(label, value),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
            ),
          ),
          if (copied)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  '$label copied',
                  style: TextStyle(fontSize: 12, color: Aether.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _status(String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(Icons.circle, size: 8, color: Aether.accent),
            const SizedBox(width: 8),
            Text('Preview status', style: AetherType.caption),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: AetherType.caption),
            ),
          ],
        ),
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
    Widget preview;
    if (_source) {
      preview = SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sourceSection(label: 'HTML', value: artifact.html),
            _sourceSection(label: 'CSS', value: artifact.css),
            _sourceSection(label: 'JavaScript', value: artifact.javascript),
          ],
        ),
      );
    } else if (_failure != null) {
      preview = SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Semantics(liveRegion: true, child: Text(_failure!)),
            const Text(
              'Retry the preview or use View source to inspect the saved artifact.',
            ),
            TextButton(
              onPressed: () => _refresh(retry: true),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    } else if (!supported) {
      preview = const SingleChildScrollView(
        padding: EdgeInsets.all(12),
        child: Text(
          'Interactive preview requires Android. Use View source to inspect this saved artifact.',
        ),
      );
    } else if (!_foreground || !_tickerEnabled || _expanded || _collapsed) {
      preview = Text(
        _expanded ? 'Preview open in fullscreen.' : 'Preview paused.',
      );
    } else {
      preview = AndroidView(
        key: ValueKey('${widget.sessionId}:${artifact.id}:$generation'),
        viewType: 'ovid/html-artifact',
        creationParams: {'document': artifact.sandboxDocument},
        creationParamsCodec: const StandardMessageCodec(),
        layoutDirection: TextDirection.ltr,
        onPlatformViewCreated: (id) => _created(id, generation),
      );
    }
    final status = _source
        ? 'Source inspection'
        : _failure != null
        ? 'Preview unavailable'
        : !supported
        ? 'Android preview unavailable'
        : !_foreground
        ? 'Paused while app is backgrounded'
        : !_tickerEnabled
        ? 'Paused while preview is inactive'
        : _expanded
        ? 'Preview open in fullscreen'
        : _collapsed
        ? 'Preview collapsed'
        : 'Ready';
    final controls = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 4,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AetherRadius.rPill),
              border: Border.all(color: Aether.textMuted.withValues(alpha: .4)),
            ),
            child: Text(
              'OFFLINE SANDBOX',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: .6,
                color: Aether.textMuted,
              ),
            ),
          ),
        ),
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
    );
    if (widget._fullscreen) {
      return PopScope<void>(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_exitFullscreen());
        },
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: math.max(
              56,
              MediaQuery.textScalerOf(context).scale(15) * 2.8 + 16,
            ),
            title: Tooltip(
              message: artifact.title,
              child: Text(
                artifact.title,
                style: AetherType.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            leading: BackButton(onPressed: _exitFullscreen),
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls,
                _status(status),
                Expanded(child: preview),
              ],
            ),
          ),
        ),
      );
    }
    // Inline: Aether card host with a collapsible preview body.
    final collapseBtn = IconButton(
      tooltip: _collapsed ? 'Open artifact' : 'Collapse artifact',
      icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less),
      onPressed: () {
        _collapsed = !_collapsed;
        _refresh();
      },
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AetherCard(
        padding: const EdgeInsets.all(12),
        title: Text(
          artifact.title,
          style: AetherType.title,
        ),
        trailing: collapseBtn,
        child: _collapsed
            ? const SizedBox.shrink()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  controls,
                  _status(status),
                  const SizedBox(height: 4),
                  SizedBox(height: height, child: preview),
                ],
              ),
      ),
    );
  }
}
