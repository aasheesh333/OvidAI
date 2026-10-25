import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/cloud/studio_preview_client.dart';

/// Android host for one ticket-bound preview launch.
///
/// The launch grant is passed only to the per-view native channel. No Ovid
/// headers or cookies are supplied, no grant is persisted, and a replaced,
/// denied, stopped, or hibernated view is destroyed rather than reused.
class StudioPreviewWebView extends StatefulWidget {
  const StudioPreviewWebView({
    super.key,
    required this.previewId,
    required this.launch,
    required this.kind,
    this.onLoaded,
    this.onError,
    this.onHibernate,
  });

  final String previewId;
  final StudioPreviewLaunch launch;
  final StudioPreviewKind kind;
  final VoidCallback? onLoaded;
  final ValueChanged<String>? onError;
  final VoidCallback? onHibernate;

  /// Hashes, never ticket strings, of launches already handed to Android.
  /// Native platform-view recreation must not silently exchange a grant twice.
  static final Set<String> _consumedLaunches = <String>{};

  @visibleForTesting
  static void resetConsumedLaunchesForTest() => _consumedLaunches.clear();

  @override
  State<StudioPreviewWebView> createState() => _StudioPreviewWebViewState();
}

class _StudioPreviewWebViewState extends State<StudioPreviewWebView>
    with WidgetsBindingObserver {
  int? _viewId;
  int _generation = 0;
  bool _failed = false;
  bool _foreground = true;

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (!_supported) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onError?.call('unsupported_renderer');
      });
    } else if (!_foreground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_foreground) widget.onHibernate?.call();
      });
    }
  }

  @override
  void didUpdateWidget(covariant StudioPreviewWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.previewId != widget.previewId ||
        oldWidget.kind != widget.kind ||
        oldWidget.launch.launchUrl != widget.launch.launchUrl) {
      unawaited(_disposeNative());
      setState(() {
        _generation++;
        _failed = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // A consumed ticket is never reused. The host must mint a fresh one.
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (!_foreground) return;
        _foreground = false;
        unawaited(_disposeNative());
        if (mounted) setState(() {});
        widget.onHibernate?.call();
    }
  }

  void _created(int id, int generation) {
    final channel = MethodChannel('ovid/studio-preview/$id');
    final previousId = _viewId;
    if (previousId != null && previousId != id) {
      unawaited(
        _disposeChannel(MethodChannel('ovid/studio-preview/$previousId')),
      );
      _viewId = null;
    }
    if (!mounted ||
        generation != _generation ||
        _failed ||
        !_foreground ||
        !_supported) {
      unawaited(_disposeChannel(channel));
      return;
    }
    _viewId = id;
    unawaited(_start(id, generation, channel));
  }

  Future<void> _start(int id, int generation, MethodChannel channel) async {
    channel.setMethodCallHandler((call) => _event(id, generation, call));
    final fingerprint = sha256
        .convert(utf8.encode(widget.launch.launchUrl))
        .toString();
    if (!StudioPreviewWebView._consumedLaunches.add(fingerprint)) {
      _fail(id, generation, 'ticket_replay');
      return;
    }
    Object? answer;
    try {
      answer = await channel.invokeMethod<Object?>('startPreview');
    } on PlatformException {
      answer = const <String, Object>{'code': 'preview_load_failed'};
    } on MissingPluginException {
      answer = const <String, Object>{'code': 'unsupported_renderer'};
    }
    if (!mounted || generation != _generation || _viewId != id) {
      await _disposeChannel(channel);
      return;
    }
    if (answer is Map) {
      _fail(id, generation, answer['code']);
    }
  }

  Future<void> _event(int id, int generation, MethodCall call) async {
    if (!mounted || generation != _generation || _viewId != id) return;
    switch (call.method) {
      case 'loadComplete':
        widget.onLoaded?.call();
        break;
      case 'loadError':
        final arguments = call.arguments;
        _fail(
          id,
          generation,
          arguments is Map ? arguments['code'] : 'preview_load_failed',
        );
        break;
    }
  }

  void _fail(int id, int generation, Object? rawCode) {
    if (!mounted || generation != _generation || _viewId != id) return;
    final code = switch (rawCode) {
      'ticket_replay' => 'ticket_replay',
      'cross_tenant' => 'cross_tenant',
      'preview_denied' => 'preview_denied',
      'unsupported_renderer' => 'unsupported_renderer',
      'renderer_gone' => 'renderer_gone',
      'invalid_launch' => 'invalid_launch',
      _ => 'preview_load_failed',
    };
    setState(() => _failed = true);
    unawaited(_disposeNative());
    widget.onError?.call(code);
  }

  Future<void> _disposeNative() async {
    final id = _viewId;
    _viewId = null;
    if (id == null) return;
    await _disposeChannel(MethodChannel('ovid/studio-preview/$id'));
  }

  Future<void> _disposeChannel(MethodChannel channel) async {
    channel.setMethodCallHandler(null);
    try {
      await channel.invokeMethod<void>('disposePreview');
    } on PlatformException {
      // AndroidView disposal still destroys the native view and its profile.
    } on MissingPluginException {
      // The platform view's own dispose callback is the remaining cleanup.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeNative());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) {
      return const Center(child: Text('Preview requires Android.'));
    }
    if (_failed) {
      return const Center(child: Text('Preview could not be loaded.'));
    }
    if (!_foreground) {
      return const Center(child: Text('Preview stopped while Ovid was away.'));
    }
    return AndroidView(
      key: ValueKey<String>(
        '${widget.previewId}:${identityHashCode(widget.launch)}:$_generation',
      ),
      viewType: 'ovid/studio-preview',
      creationParams: <String, Object>{
        'previewId': widget.previewId,
        'launchUrl': widget.launch.launchUrl,
        'kind': widget.kind.wireValue,
      },
      creationParamsCodec: const StandardMessageCodec(),
      layoutDirection: TextDirection.ltr,
      onPlatformViewCreated: (id) => _created(id, _generation),
    );
  }
}
