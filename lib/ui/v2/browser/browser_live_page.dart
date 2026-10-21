import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/cloud/browser_stream.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud/cloud_ws.dart';
import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'browser_page.dart';
import 'take_control_sheet.dart';
import 'viewport.dart';

/// The live browser screen: the one place the v2 Browser page talks to the
/// cloud browser.
///
/// The [BrowserPage] below stays presentational. This widget owns the
/// [BrowserStreamClient] and turns its state into the page's data:
///
///  * tabs and the address come from `browser_state`, so the strip shows what
///    the agent actually opened — there is no client-side tab creation;
///  * a screencast frame becomes a real [ImageProvider] for the viewport;
///  * "Take control" sends the server's takeover request and the controlled
///    state only appears after the server acknowledges it;
///  * a tap on the picture while controlling is sent as page input;
///  * the keyboard tool is a real text bridge to `browser_input`.
///
/// Controls the server cannot support (history, upload, download, closing a
/// tab) are simply not passed, so the page never renders a dead button.
class BrowserLivePage extends StatefulWidget {
  const BrowserLivePage({
    super.key,
    this.client,
    this.sessionId,
    this.attachId,
    this.firstStateTimeout = const Duration(seconds: 5),
    this.stallTimeout = const Duration(seconds: 6),
  });

  /// Test seam: a client wired to fake streams instead of the singleton.
  final BrowserStreamClient? client;

  /// The chat this screen was opened from (local or server id). Only used to
  /// pick the attach id; every chat shows the same per-user browser.
  final String? sessionId;

  /// Test seam: the exact attach id, skipping local→server resolution.
  final String? attachId;

  /// How long to wait for the first `browser_state` before saying plainly
  /// that Ovid has not opened the browser.
  final Duration firstStateTimeout;

  /// How long a gap between frames counts as a stalled picture.
  final Duration stallTimeout;

  @override
  State<BrowserLivePage> createState() => _BrowserLivePageState();
}

class _BrowserLivePageState extends State<BrowserLivePage>
    with WidgetsBindingObserver {
  late final BrowserStreamClient _client;

  StreamSubscription<BrowserFrame>? _framesSub;
  Timer? _firstStateTimer;
  Timer? _stallTimer;

  BrowserFrame? _frame;
  ImageProvider? _frameProvider;

  /// Seconds since the last frame, counted by the stall timer (not wall
  /// clock) so the screen can be tested with fake time.
  int _quietSeconds = 0;

  bool _waitExpired = false;
  bool _stalled = false;

  /// The keyboard tool is a notifier so the take-control sheet can listen to
  /// it alongside the client and repaint its chip immediately.
  final ValueNotifier<bool> _keyboard = ValueNotifier<bool>(false);

  bool _backgrounded = false;
  String? _attachId;
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = widget.client ?? BrowserStreamClient.I;
    _client.addListener(_onClientChanged);
    _framesSub = _client.frames.listen(_onFrame);
    _startFirstStateTimer();
    unawaited(_attach());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _firstStateTimer?.cancel();
    _stallTimer?.cancel();
    _client.removeListener(_onClientChanged);
    unawaited(_framesSub?.cancel());
    final image = _frame?.image;
    _frame = null;
    image?.dispose();
    // Closing the viewer detaches: the worker keeps rendering for its grace
    // window, then goes headless instead of streaming to nobody.
    _client.detach();
    _keyboard.dispose();
    super.dispose();
  }

  Future<String> _resolveAttachId() async {
    final local = widget.sessionId ?? AppState.I.activeSessionId ?? '';
    if (local.isEmpty) return BrowserStreamClient.userAlias;
    try {
      final store = CloudSessionStore.I;
      await store.ready;
      return store.knownServerIdFor(local) ?? BrowserStreamClient.userAlias;
    } catch (_) {
      // No cloud store (isolated widget test): the alias still reaches the
      // user's one browser.
      return BrowserStreamClient.userAlias;
    }
  }

  Future<void> _attach() async {
    final id = widget.attachId ?? _attachId ?? await _resolveAttachId();
    if (!mounted || _backgrounded) return;
    _attachId = id;
    await _client.attach(id);
    _startStallTimer();
  }

  void _startFirstStateTimer() {
    _firstStateTimer?.cancel();
    _waitExpired = false;
    _firstStateTimer = Timer(widget.firstStateTimeout, () {
      if (!mounted) return;
      // No state yet, or a state without a picture: either way the screen
      // stops pretending to load and says what is happening.
      if (_frame == null && _client.error == null) {
        setState(() => _waitExpired = true);
      }
    });
  }

  void _startStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final state = _client.state;
      if (state == null || !state.live || !state.screencast) return;
      if (_frame == null) return;
      _quietSeconds++;
      final stalled = _quietSeconds > widget.stallTimeout.inSeconds;
      if (stalled != _stalled) setState(() => _stalled = stalled);
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
        _stallTimer?.cancel();
        _client.detach();
      case AppLifecycleState.resumed:
        if (!_backgrounded) return;
        _backgrounded = false;
        _clearFrame();
        unawaited(_attach());
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _onClientChanged() {
    if (!mounted) return;
    if (_client.error != null) _firstStateTimer?.cancel();
    if (!_client.takeoverActive && _keyboard.value) _keyboard.value = false;
    setState(() {});
    final notice = _client.notice;
    if (notice != null) {
      _client.clearNotice();
      _snack(
        notice.code == 'not_controller'
            ? 'The browser is being controlled on another device.'
            : 'Reconnecting to the browser…',
      );
      if (notice.code == 'not_attached' && _attachId != null) {
        unawaited(_client.attach(_attachId!));
      }
    }
  }

  void _onFrame(BrowserFrame frame) {
    if (!mounted) return;
    _firstStateTimer?.cancel();
    final old = _frame;
    setState(() {
      _frame = frame;
      // The decoded bytes are a real ImageProvider; the viewport paints it.
      _frameProvider = MemoryImage(frame.webpBytes);
      _quietSeconds = 0;
      _stalled = false;
      _waitExpired = false;
    });
    // The decoded image is ours to release. Do it after the frame that
    // replaced it has painted, so the render tree never draws a disposed
    // image.
    final image = old?.image;
    if (image != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
    }
  }

  void _clearFrame() {
    final old = _frame;
    setState(() {
      _frame = null;
      _frameProvider = null;
      _quietSeconds = 0;
      _stalled = false;
      _waitExpired = false;
    });
    old?.image?.dispose();
  }

  Future<void> _retry() async {
    _clearFrame();
    _client.detach();
    _startFirstStateTimer();
    await _attach();
  }

  void _snack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyAddress() async {
    final url = _client.state?.url;
    if (url == null || url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    _snack('Address copied');
  }

  Future<void> _openExternal() async {
    final url = _client.state?.url;
    if (url == null || url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      _snack('No app can open this address.');
    }
  }

  Future<void> _openMenu() async {
    final url = _client.state?.url;
    final hasUrl = url != null && url.isNotEmpty;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: OColors.of(context).surface,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OListRow(
              title: 'Copy address',
              icon: Icons.content_copy_rounded,
              enabled: hasUrl,
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_copyAddress());
              },
            ),
            OListRow(
              title: 'Open in browser',
              icon: Icons.open_in_new_rounded,
              enabled: hasUrl,
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openExternal());
              },
            ),
            OListRow(
              title: 'Reconnect',
              subtitle: 'Attach to the live view again',
              icon: Icons.refresh_rounded,
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_retry());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _takeControl() async {
    if (_client.controlledElsewhere) {
      _snack('The browser is being controlled on another device.');
      return;
    }
    if (!_client.canTakeOver) {
      _snack('There is no live page to control yet.');
      return;
    }
    if (_sheetOpen) return;
    _sheetOpen = true;
    var closing = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (sheetContext) => AnimatedBuilder(
        // The sheet follows both the server state and the local keyboard
        // tool, so its chip reflects the real toggle.
        animation: Listenable.merge(<Listenable>[_client, _keyboard]),
        builder: (context, _) {
          if (_client.takeoverActive && !closing) {
            closing = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (sheetContext.mounted) {
                Navigator.of(sheetContext).maybePop();
              }
            });
          }
          return TakeControlSheet(
            data: V2TakeControlData(
              status: _sheetStatus,
              countdownLabel: 'Ovid is driving this page',
              keyboard: _keyboard.value,
            ),
            onStart: _client.takeoverPending ? null : _requestTakeover,
            onStayWatching: () => Navigator.of(sheetContext).maybePop(),
            onToggleKeyboard: _toggleKeyboard,
            onRetry: _requestTakeover,
          );
        },
      ),
    );
    _sheetOpen = false;
  }

  V2TakeControlStatus get _sheetStatus {
    if (_client.takeoverFailed) return V2TakeControlStatus.error;
    if (_client.takeoverPending) return V2TakeControlStatus.loading;
    return V2TakeControlStatus.ready;
  }

  Future<void> _requestTakeover() async {
    await _client.requestTakeover();
  }

  void _toggleKeyboard() {
    setState(() => _keyboard.value = !_keyboard.value);
  }

  void _onPageTap(double x, double y) {
    final state = _client.state;
    if (state == null || !_client.takeoverActive) return;
    _client.sendTap(x * state.viewportWidth, y * state.viewportHeight);
  }

  static String _hostOf(String? url) {
    final uri = Uri.tryParse(url ?? '');
    final host = uri?.host ?? '';
    return host.isEmpty ? (url ?? '') : host;
  }

  String _errorCopy(BrowserStreamError error) {
    return switch (error.code) {
      'forbidden' => "This chat isn't on your account, so its browser can't be "
          'shown.',
      'unavailable' => 'The cloud browser is not available right now.',
      'unauthenticated' =>
        'Your sign-in expired. Sign in again to view the browser.',
      _ => "Couldn't connect to the cloud browser.",
    };
  }

  V2BrowserConnection get _connection {
    if (_client.linkState == WsLinkState.online) {
      return V2BrowserConnection.live;
    }
    return _client.reconnecting
        ? V2BrowserConnection.reconnecting
        : V2BrowserConnection.offline;
  }

  V2BrowserStatus get _status {
    if (_client.error != null) return V2BrowserStatus.error;
    final state = _client.state;
    if (state == null) {
      return _waitExpired ? V2BrowserStatus.empty : V2BrowserStatus.loading;
    }
    if (state.tabs.isEmpty && (state.url == null || state.url!.isEmpty)) {
      return V2BrowserStatus.empty;
    }
    return V2BrowserStatus.content;
  }

  V2ViewportStatus get _viewportStatus {
    final state = _client.state;
    if (state == null) return V2ViewportStatus.loading;
    if (_frame == null) {
      if (!state.live) return V2ViewportStatus.waiting;
      return _waitExpired
          ? V2ViewportStatus.waiting
          : V2ViewportStatus.loading;
    }
    if (_stalled || !state.screencast) return V2ViewportStatus.streamLost;
    if (!state.live) return V2ViewportStatus.streamLost;
    return V2ViewportStatus.live;
  }

  V2BrowserData _data() {
    final state = _client.state;
    final controlling = _client.takeoverActive;
    final tabs = <V2BrowserTab>[];
    if (state != null) {
      for (final tab in state.tabs) {
        final host = _hostOf(tab.url);
        final title = (tab.title ?? '').trim();
        tabs.add(
          V2BrowserTab(
            id: '${tab.index}',
            title: title.isEmpty ? host : title,
            host: host,
            // Tabs are agent-owned and the gateway has no close op.
            closable: false,
          ),
        );
      }
    }
    final status = _status;
    return V2BrowserData(
      tabs: tabs,
      activeTabId: state == null ? '' : '${state.activeTabIndex}',
      address: state?.url ?? '',
      readOnly: !controlling,
      drivingTitle: controlling ? 'You are driving' : 'Ovid is driving',
      drivingDetail: controlling
          ? 'Tap the page to click. Use the keyboard tool to type.'
          : _client.controlledElsewhere
          ? 'Another device is controlling this page'
          : state?.live == true
          ? 'The live view refreshes 3–5 times a second'
          : 'Starting the browser',
      liveLabel: controlling ? 'You are in control' : 'Live',
      streamLabel: state == null
          ? ''
          : '${state.viewportWidth}×${state.viewportHeight}',
      // The server's 45 s headless countdown is not part of the client state
      // this build parses, so no invented countdown is shown.
      headlessLabel: '',
      connection: _connection,
      actions: const <V2BrowserAction>[],
      status: status,
      frame: _frameProvider,
      viewportStatus: _viewportStatus,
      controlling: controlling,
      keyboard: _keyboard.value,
      canGoBack: false,
      canGoForward: false,
      viewportAspectRatio: state == null
          ? null
          : state.viewportWidth / state.viewportHeight,
      fpsLabel: '3–5 fps',
      emptyTitle: _waitExpired && state == null
          ? 'Ovid has not opened the browser'
          : 'No page open',
      emptyMessage: _waitExpired && state == null
          ? 'Ovid opens the browser when a task needs it. This screen updates '
                'on its own, or you can try again.'
          : 'Ask Ovid to open a page and it will show up here.',
      errorMessage: _client.error == null
          ? 'The live view lost its connection.'
          : _errorCopy(_client.error!),
      offlineMessage: 'Ovid will reconnect on its own. You can also try now.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data();
    return Stack(
      children: [
        BrowserPage(
          data: data,
          onMenu: _openMenu,
          onCopyAddress: _copyAddress,
          onSelectTab: (id) {
            final index = int.tryParse(id);
            if (index != null) unawaited(_client.switchTab(index));
          },
          onTakeControl: _client.canTakeOver && !_client.controlledElsewhere
              ? _takeControl
              : null,
          onReleaseControl: _client.takeoverActive
              ? () => unawaited(_client.releaseTakeover())
              : null,
          onToggleKeyboard: _client.takeoverActive ? _toggleKeyboard : null,
          onRetry: _retry,
          onPageTap: _onPageTap,
        ),
        // The soft keyboard bridge exists only while the person holds control
        // and switched the keyboard tool on.
        if (_keyboard.value && _client.takeoverActive)
          Positioned(
            left: 0,
            bottom: 0,
            width: 1,
            height: 1,
            child: Material(
              type: MaterialType.transparency,
              child: _KeyboardBridge(
                key: const ValueKey('v2-browser-keyboard-bridge'),
                onText: _client.sendText,
                onKey: _client.sendKey,
              ),
            ),
          ),
      ],
    );
  }
}

/// A 1 × 1 text field that owns the soft keyboard and forwards keystrokes to
/// the page. A sentinel keeps deletions detectable: anything removed from the
/// sentinel is a Backspace, anything typed after it is inserted text.
class _KeyboardBridge extends StatefulWidget {
  const _KeyboardBridge({super.key, required this.onText, required this.onKey});

  final ValueChanged<String> onText;
  final ValueChanged<String> onKey;

  @override
  State<_KeyboardBridge> createState() => _KeyboardBridgeState();
}

class _KeyboardBridgeState extends State<_KeyboardBridge> {
  static const String _sentinel = '\u200B\u200B';

  final TextEditingController _controller = TextEditingController(
    text: _sentinel,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'v2-browser-keyboard');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _reset() {
    _controller.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  void _onChanged(String value) {
    if (value.startsWith(_sentinel)) {
      final typed = value.substring(_sentinel.length);
      if (typed.isEmpty) return;
      widget.onText(typed);
      _reset();
      return;
    }
    if (_sentinel.startsWith(value)) {
      // Backspace ate into the sentinel: one key per missing character.
      final removed = _sentinel.length - value.length;
      for (var i = 0; i < removed; i++) {
        widget.onKey('Backspace');
      }
      _reset();
      return;
    }
    // The field was replaced wholesale (paste, IME, autofill): insert it.
    if (value.isNotEmpty) widget.onText(value);
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      height: 1,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        onChanged: _onChanged,
        onSubmitted: (_) {
          widget.onKey('Enter');
          _reset();
        },
        decoration: const InputDecoration.collapsed(hintText: ''),
      ),
    );
  }
}
