import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/html_artifact.dart';

/// Inline chat artifact host. The native view is deliberately independent of
/// browser tabs, auth controllers and plugin UI. Removing it destroys the
/// document (source/collapse/background/session switch); reopening starts fresh.
class HtmlArtifactView extends StatefulWidget {
  final HtmlArtifact? artifact;
  final String sessionId;

  const HtmlArtifactView({
    super.key,
    required this.artifact,
    required this.sessionId,
  });

  @override
  State<HtmlArtifactView> createState() => _HtmlArtifactViewState();
}

class _HtmlArtifactViewState extends State<HtmlArtifactView>
    with WidgetsBindingObserver {
  bool _source = false;
  bool _expanded = false;
  bool _collapsed = false;
  bool _foreground = true;
  int? _viewId;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(HtmlArtifactView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artifact?.id != widget.artifact?.id ||
        oldWidget.sessionId != widget.sessionId) {
      _source = _expanded = _collapsed = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      // A paused Flutter engine does not paint setState. Stop native execution
      // immediately, without waiting for another frame to unmount AndroidView.
      final id = _viewId;
      if (id != null) {
        unawaited(
          MethodChannel(
            'ovid/html-artifact/$id',
          ).invokeMethod<void>('disposeDocument').catchError((Object _) {}),
        );
      }
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
    // Explicit resize rather than a bridge reading untrusted document height.
    // Never grow beyond the viewport; the document scrolls inside its frame.
    final viewport = MediaQuery.sizeOf(context).height;
    final height = math.max(
      160.0,
      math.min(
        _expanded ? viewport * .75 : artifact.height.toDouble(),
        math.max(160.0, viewport * .75),
      ),
    );
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
                  onPressed: () => setState(() => _collapsed = !_collapsed),
                ),
              ],
            ),
          ),
          if (!_collapsed) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(4),
                    child: Text(
                      'Offline sandbox',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                  IconButton(
                    tooltip: _source ? 'Show preview' : 'View source',
                    icon: Icon(_source ? Icons.preview_outlined : Icons.code),
                    onPressed: () => setState(() => _source = !_source),
                  ),
                  IconButton(
                    tooltip: _expanded ? 'Shrink preview' : 'Expand preview',
                    icon: Icon(
                      _expanded ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
                ],
              ),
            ),
            if (_source)
              SizedBox(
                height: height,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    '${artifact.html}\n\n/* CSS */\n${artifact.css}\n\n// JavaScript\n${artifact.javascript}',
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            else if (!supported)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Interactive preview requires Android. Use View source to inspect this saved artifact.',
                ),
              )
            else if (!_foreground || !TickerMode.valuesOf(context).enabled)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Preview paused.'),
              )
            else
              SizedBox(
                height: height,
                child: AndroidView(
                  key: ValueKey(
                    '${widget.sessionId}:${artifact.id}:$_generation',
                  ),
                  viewType: 'ovid/html-artifact',
                  creationParams: {'document': artifact.sandboxDocument},
                  creationParamsCodec: const StandardMessageCodec(),
                  layoutDirection: TextDirection.ltr,
                  onPlatformViewCreated: (id) => _viewId = id,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
