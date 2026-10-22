import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/cloud/browser_stream.dart';
import '../../../core/cloud/cloud_session_store.dart';
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
/// The gateway accepts exactly five viewer ops for a browser attach —
/// `browser_attach`, `browser_detach`, `browser_input`, `browser_takeover`
/// and `browser_switch_tab` (`cloud/packages/shared/src/ws.ts`) — and the
/// only browser op it sends back is `browser_state`
/// (`cloud/packages/shared/src/browser.ts`); frames arrive as binary
/// messages and failures as `error` ops. The screen therefore omits the
/// rest instead of rendering dead buttons:
///
///  * **history (back / forward)** and **reload** — no viewer op and no
///    `browser_state` field for them, so a tap could not reach the page.
///    `browser_input` only presses keys into the page (`input.ts`), not
///    browser chrome. The agent can do all three (`browser_back`,
///    `browser_forward`, `browser_reload`); the viewer cannot.
///  * **upload** — no viewer op. `browser_upload` is an agent tool that takes
///    a workspace path (`cloud/packages/browser/src/tools/transfers.ts`), not
///    bytes from a viewer's file picker, so a file input here would go
///    nowhere.
///  * **download** — no viewer op, and neither `browser_state` nor any
///    browser channel carries a download name or URL. `browser_download` and
///    page-initiated saves write into the owning chat's workspace and emit an
///    `artifact_created` event on that chat's stream
///    (`cloud/packages/browser/src/tools/downloadWiring.ts`), which this
///    screen does not subscribe to; the file appears in the chat transcript
///    and the Artifacts library instead.
///  * **close tab** — no close op (and no `new_tab`): tabs are agent-owned
///    (`browser_new_tab` / `browser_close_tab`), so `closable: false` is
///    passed for every tab and the strip draws no close control.
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

  /// The attach generation the picture on screen belongs to. A new generation
  /// (retry, tab replace, socket reconnect) invalidates it.
  int _generation = 0;

  /// A hand-back timeout is reported once per failed request, not on every
  /// repaint.
  bool _releaseFailureShown = false;

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
    try {
      await _client.attach(id);
    } catch (_) {
      // The link layer owns reconnects; the page stays on its honest waiting
      // surface instead of dying on an unhandled future error.
    }
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

    // A new attach generation (first attach, retry, reconnect) means the
    // picture on screen belongs to a session the server is no longer
    // streaming. Drop it instead of painting a stale page as live, and give
    // the new session the same honest waiting window as a cold open.
    final generation = _client.generation;
    if (generation != _generation) {
      final firstAttach = _generation == 0;
      _generation = generation;
      _clearFrame();
      if (!firstAttach) _startFirstStateTimer();
    }

    // Handing control back is server-acknowledged too. If the ack never
    // comes, stay controlled (never fake the release) but say so once and
    // leave the return button in place to try again.
    if (_client.takeoverFailed && _client.takeoverActive) {
      if (!_releaseFailureShown) {
        _releaseFailureShown = true;
        _snack('Still controlling. Try again.');
      }
    } else {
      _releaseFailureShown = false;
    }

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
        // The server dropped this viewer's attach. `attach()` alone is a
        // no-op while the client still believes it is attached, so drop the
        // stale picture and re-attach from scratch.
        unawaited(_retry());
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

  /// Selects an agent tab. The old tab's picture is dropped immediately: the
  /// address is about to change, so leaving its last frame on screen would be
  /// a lie until the new tab's first frame arrives.
  Future<void> _switchTab(int index) async {
    _clearFrame();
    _startFirstStateTimer();
    try {
      await _client.switchTab(index);
    } catch (_) {
      // The switch did not leave this device. Stay on the waiting surface;
      // the retry action re-attaches.
    }
  }

  /// Hands the page back to Ovid. The dock only changes once the server
  /// acknowledges, so a failed request keeps control here.
  Future<void> _releaseControl() async {
    try {
      await _client.releaseTakeover();
    } catch (_) {
      if (mounted) _snack('Could not hand back control.');
    }
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
        // The sheet follows the server state, so its state reflects the real
        // takeover request rather than an optimistic local guess.
        animation: _client,
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
            data: V2TakeControlData(status: _sheetStatus),
            onStart: _client.takeoverPending ? null : _requestTakeover,
            onStayWatching: () => Navigator.of(sheetContext).maybePop(),
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
    try {
      await _client.requestTakeover();
    } catch (_) {
      if (!mounted) return;
      // The sheet is already open; a failure to send is the same outcome as
      // an unacknowledged request, so say it plainly.
      _snack('Could not pause the page. Try again.');
    }
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
      'forbidden' =>
        "This chat isn't on your account, so its browser can't be "
            'shown.',
      'unavailable' => 'The cloud browser is not available right now.',
      'unauthenticated' =>
        'Your sign-in expired. Sign in again to view the browser.',
      _ => "Couldn't connect to the cloud browser.",
    };
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
    // The socket is down: the last frame is a still picture of a page this
    // device can no longer drive. Say the stream is lost instead of painting
    // it as live while the link is gone.
    if (_client.reconnecting) return V2ViewportStatus.streamLost;
    if (state == null) return V2ViewportStatus.loading;
    if (_frame == null) {
      if (!state.live) return V2ViewportStatus.waiting;
      return _waitExpired ? V2ViewportStatus.waiting : V2ViewportStatus.loading;
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
            // Tabs are agent-owned: no viewer close op exists (see the
            // class doc comment).
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
      status: status,
      frame: _frameProvider,
      viewportStatus: _viewportStatus,
      // Straight from `browser_state`: null fps stays unknown (no number is
      // painted), and headless only shows when the server says so.
      fps: state?.fps,
      headless: state?.headless ?? false,
      controlling: controlling,
      keyboard: _keyboard.value,
      // No viewer history op and no `browser_state` field for it, so no back
      // / forward control is passed and the bar does not render one.
      canGoBack: false,
      canGoForward: false,
      viewportAspectRatio: state == null
          ? null
          : state.viewportWidth / state.viewportHeight,
      emptyTitle: _waitExpired && state == null
          ? 'Browser not open'
          : 'No page open',
      emptyMessage: _waitExpired && state == null
          ? 'Ovid opens the browser when a task needs it.'
          : 'Pages Ovid opens appear here.',
      errorMessage: _client.error == null
          ? 'The live view lost its connection.'
          : _errorCopy(_client.error!),
    );
  }

  /// Control is only offered when there is a picture to control: taking over a
  /// page this device cannot see would hand over taps nobody can aim.
  bool get _canTakeControl =>
      _client.canTakeOver &&
      !_client.controlledElsewhere &&
      _viewportStatus == V2ViewportStatus.live;

  @override
  Widget build(BuildContext context) {
    final data = _data();
    return Stack(
      children: [
        BrowserPage(
          data: data,
          onMenu: _openMenu,
          onSelectTab: (id) {
            final index = int.tryParse(id);
            if (index != null) unawaited(_switchTab(index));
          },
          onTakeControl: _canTakeControl ? _takeControl : null,
          onReleaseControl: _client.takeoverActive ? _releaseControl : null,
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
