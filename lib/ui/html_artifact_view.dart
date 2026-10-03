import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/diag.dart';
import '../core/html_artifact.dart';

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
        child: SelectableText(
          '${artifact.html}\n\n/* CSS */\n${artifact.css}\n\n// JavaScript\n${artifact.javascript}',
          style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
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
      preview = const Text(
        'Interactive preview requires Android. Use View source to inspect this saved artifact.',
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
    final controls = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Padding(
          padding: EdgeInsets.all(4),
          child: Text('Offline sandbox', style: TextStyle(fontSize: 11)),
        ),
        IconButton(
          tooltip: _source ? 'Show preview' : 'View source',
          icon: Icon(_source ? Icons.preview_outlined : Icons.code),
          onPressed: () {
            _source = !_source;
            _refresh();
          },
        ),
        IconButton(
          tooltip: widget._fullscreen ? 'Exit fullscreen' : 'Expand preview',
          icon: Icon(
            widget._fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          ),
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
            title: Text(artifact.title),
            leading: BackButton(onPressed: _exitFullscreen),
          ),
          body: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls,
                Expanded(child: preview),
              ],
            ),
          ),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    artifact.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: _collapsed ? 'Open artifact' : 'Collapse artifact',
                  icon: Icon(
                    _collapsed ? Icons.expand_more : Icons.expand_less,
                  ),
                  onPressed: () {
                    _collapsed = !_collapsed;
                    _refresh();
                  },
                ),
              ],
            ),
          ),
          if (!_collapsed) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: controls,
            ),
            SizedBox(height: height, child: preview),
          ],
        ],
      ),
    );
  }
}
