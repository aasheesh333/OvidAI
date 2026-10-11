import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/mcp_oauth_discovery.dart';
import '../core/mcp_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Opens a URL for sign-in. Injectable so widget tests can observe the exact
/// authorization URL the sheet hands to the platform.
typedef McpOAuthLauncher = Future<bool> Function(Uri uri);

/// Thin seam over the browser OAuth flow. The sheet only needs the
/// authorization URL, the full callback URI, and cancellation, so the service
/// keeps ownership of its attempt/state/PKCE material. Production wires the
/// [McpService] implementation at the composition root (see plugins_screen).
abstract class McpOAuthService {
  /// Begin a fresh authorization attempt and return the URL to open.
  Future<String> beginAuthorization(String serverKey);

  /// Complete the attempt with the FULL callback URI (captured redirect or
  /// pasted by the user).
  Future<void> completeAuthorization(String serverKey, String callbackUri);

  /// Discard the pending attempt for [serverKey].
  void cancelAuthorization(String serverKey);

  /// When the pending attempt expires, or null when unknown.
  Future<DateTime?> attemptExpiry(String serverKey);
}

/// Delivers OAuth redirects captured by the app (App Link / custom scheme)
/// to an open [McpOAuthSheet]. When no sheet listens (the app was killed
/// while the browser was in front), the root link handler completes the
/// callback itself.
class McpOAuthCallbackHub {
  McpOAuthCallbackHub._();

  static final _controller = StreamController<Uri>.broadcast();

  static Stream<Uri> get stream => _controller.stream;

  /// True while a sign-in sheet is open and waiting for a redirect.
  static bool get hasListener => _controller.hasListener;

  static void deliver(Uri uri) => _controller.add(uri);
}

/// Root handler for an OAuth redirect captured by the app (main.dart).
///
/// An open sign-in sheet gets it through [McpOAuthCallbackHub]. Otherwise
/// (Android killed the app while the browser was in front) the attempt is
/// restored from secure storage by its `state`, completed here, and the
/// server is reconnected — the user lands back signed in.
Future<void> handleMcpOAuthRedirect(
  Uri uri, {
  ScaffoldMessengerState? messenger,
}) async {
  if (McpOAuthCallbackHub.hasListener) {
    McpOAuthCallbackHub.deliver(uri);
    return;
  }
  void say(String text) => messenger?.showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
  );
  final key = await McpService.I.mcpOAuthServerForCallback(uri);
  if (key == null) {
    say(
      'That sign-in link has expired. Open the server in Plugins and sign '
      'in again.',
    );
    return;
  }
  final server = AppState.I.mcpServers
      .where((s) => s.canonicalId == key)
      .firstOrNull;
  final name = server?.name ?? key;
  try {
    await McpService.I.completeMcpOAuthAuthorization(key, uri.toString());
  } catch (e) {
    say('Sign-in to $name failed: ${mcpOAuthErrorCopy(e)}');
    return;
  }
  say('Signed in to $name');
  if (server != null && !server.connected) {
    await AppState.I.toggleMcpServer(server);
  }
}

/// Opens [uri] in a Custom Tab (in-app browser view) so the redirect comes
/// straight back to the app; falls back to the external browser.
Future<bool> defaultMcpOAuthLauncher(Uri uri) async {
  try {
    if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
  } catch (_) {
    // Custom Tabs unavailable — fall through to the external browser.
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// Plain-language copy for an OAuth failure (03 §11): never a raw
/// `Bad state:` string.
String mcpOAuthErrorCopy(Object error) {
  if (error is McpOAuthException) {
    return switch (error.kind) {
      McpOAuthErrorKind.denied =>
        error.message.endsWith('access_denied')
            ? 'You declined access.'
            : 'The sign-in page returned an error.',
      McpOAuthErrorKind.stateMismatch =>
        'That address is from an older sign-in attempt.',
      McpOAuthErrorKind.redirectMismatch =>
        'Paste the address you were redirected to after signing in, not '
            'the sign-in link.',
      McpOAuthErrorKind.expired =>
        'That sign-in link expired or was already used.',
      McpOAuthErrorKind.tokenExchange =>
        error.status == null
            ? 'The server rejected the sign-in.'
            : 'The server rejected the sign-in (HTTP ${error.status}).',
      McpOAuthErrorKind.config =>
        "This server's OAuth settings are invalid: ${error.message}",
      McpOAuthErrorKind.discovery => error.message,
      McpOAuthErrorKind.replaced =>
        'The server was changed or removed while signing in.',
    };
  }
  return 'Could not complete sign-in.';
}

/// Present the browser-based MCP OAuth sheet. Pops `true` after a successful
/// completion and `false` on cancel.
Future<bool?> showMcpOAuthSheet(
  BuildContext context, {
  required String serverKey,
  required String serverName,
  required McpOAuthService service,
  McpOAuthLauncher launcher = defaultMcpOAuthLauncher,
  Stream<Uri>? callbacks,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => McpOAuthSheet(
      serverKey: serverKey,
      serverName: serverName,
      service: service,
      launcher: launcher,
      callbacks: callbacks,
    ),
  );
}

/// Aether-primitive OAuth sheet: opens the authorization page in a Custom
/// Tab and completes automatically when the redirect comes back. Pasting
/// the redirect address stays available as a fallback.
class McpOAuthSheet extends StatefulWidget {
  const McpOAuthSheet({
    super.key,
    required this.serverKey,
    required this.serverName,
    required this.service,
    this.launcher = defaultMcpOAuthLauncher,
    this.callbacks,
  });

  final String serverKey;
  final String serverName;
  final McpOAuthService service;
  final McpOAuthLauncher launcher;

  /// Captured redirects; defaults to [McpOAuthCallbackHub.stream].
  final Stream<Uri>? callbacks;

  @override
  State<McpOAuthSheet> createState() => _McpOAuthSheetState();
}

class _McpOAuthSheetState extends State<McpOAuthSheet> {
  final _callbackController = TextEditingController();
  bool _loading = true;
  bool _completing = false;
  bool _showPaste = false;
  bool _copied = false;
  String? _authorizationUrl;
  String? _beginError;
  String? _callbackError;
  String? _notice;
  String _phase = 'Starting sign-in';
  IconData _phaseIcon = Icons.hourglass_empty;
  bool _cancelled = false;
  DateTime? _expiresAt;
  Timer? _ticker;
  StreamSubscription<Uri>? _callbackSub;

  @override
  void initState() {
    super.initState();
    _callbackSub = (widget.callbacks ?? McpOAuthCallbackHub.stream).listen(
      _onCapturedCallback,
    );
    _begin();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _callbackSub?.cancel();
    _callbackController.dispose();
    super.dispose();
  }

  void _setPhase(String text, IconData icon) {
    _phase = text;
    _phaseIcon = icon;
  }

  Future<void> _begin({String? notice}) async {
    _cancelled = false;
    _ticker?.cancel();
    setState(() {
      _loading = true;
      _beginError = null;
      _notice = notice;
      _expiresAt = null;
      _copied = false;
      _setPhase('Starting sign-in', Icons.hourglass_empty);
    });
    try {
      final url = await widget.service.beginAuthorization(widget.serverKey);
      if (!mounted || _cancelled) return;
      DateTime? expires;
      try {
        expires = await widget.service.attemptExpiry(widget.serverKey);
      } catch (_) {
        expires = null;
      }
      if (!mounted || _cancelled) return;
      setState(() {
        _authorizationUrl = url;
        _expiresAt = expires;
        _loading = false;
        _setPhase('Sign-in link ready', Icons.link);
      });
      _startTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _beginError = mcpOAuthErrorCopy(e);
        _loading = false;
        _setPhase('Sign-in could not start', Icons.error_outline);
      });
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    if (_expiresAt == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final left = _expiresAt!.difference(DateTime.now());
      if (left.isNegative && !_completing) {
        _ticker?.cancel();
        _begin(notice: 'The link expired — a new one is ready.');
        return;
      }
      setState(() {});
    });
  }

  String? _expiryLabel() {
    final at = _expiresAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    if (left.isNegative) return 'Link expired';
    final m = left.inMinutes;
    final s = (left.inSeconds % 60).toString().padLeft(2, '0');
    return 'Link expires in $m:$s';
  }

  Future<void> _openBrowser() async {
    final url = _authorizationUrl;
    if (url == null) return;
    setState(() {
      _notice = null;
      _setPhase('Opening sign-in page', Icons.open_in_new);
    });
    var launched = false;
    try {
      launched = await widget.launcher(Uri.parse(url));
    } catch (_) {
      launched = false;
    }
    if (!mounted) return;
    setState(() {
      if (launched) {
        _setPhase(
          'Waiting for you to finish signing in',
          Icons.hourglass_top_outlined,
        );
      } else {
        _setPhase(
          'Could not open the browser — copy the link below',
          Icons.error_outline,
        );
        _showPaste = true;
      }
    });
  }

  void _onCapturedCallback(Uri uri) {
    final state = uri.queryParameters['state'];
    final url = _authorizationUrl;
    // Ignore redirects for other sign-ins (another server's attempt).
    if (url == null ||
        _completing ||
        state == null ||
        Uri.tryParse(url)?.queryParameters['state'] != state) {
      return;
    }
    _complete(uri.toString());
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    _callbackController.text = text;
    setState(() => _callbackError = null);
  }

  Future<void> _complete([String? captured]) async {
    final callback = captured ?? _callbackController.text.trim();
    if (callback.isEmpty) {
      setState(
        () => _callbackError =
            'Paste the full address from the browser after signing in.',
      );
      return;
    }
    setState(() {
      _completing = true;
      _callbackError = null;
      _notice = null;
      _setPhase('Finishing sign-in', Icons.sync);
    });
    try {
      await widget.service.completeAuthorization(widget.serverKey, callback);
      if (!mounted) return;
      _callbackController.clear();
      setState(() => _setPhase('Signed in', Icons.check_circle_outline));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      final copy = mcpOAuthErrorCopy(e);
      final keepLink = e is McpOAuthException && e.attemptStillValid;
      setState(() {
        _completing = false;
        _callbackError = copy;
        _setPhase('Sign-in failed', Icons.error_outline);
      });
      if (!keepLink) {
        // The attempt was used up: start a fresh one so a retry works.
        _callbackController.clear();
        await _begin(notice: 'Link refreshed — open the browser again.');
        if (mounted) setState(() => _callbackError = copy);
      }
    }
  }

  void _cancel() {
    _cancelled = true;
    widget.service.cancelAuthorization(widget.serverKey);
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_completing) _cancel();
      },
      child: AetherSheet(
        title: 'Sign in to ${widget.serverName}',
        actions: [
          AetherGhostButton(
            key: const ValueKey('mcp-oauth-cancel'),
            label: 'Cancel',
            onPressed: _completing ? null : _cancel,
          ),
        ],
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _phaseRow(),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_beginError != null)
                _errorView()
              else
                _readyView(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phaseRow() {
    final expiry = _loading ? null : _expiryLabel();
    return Semantics(
      liveRegion: true,
      container: true,
      child: Row(
        key: const ValueKey('mcp-oauth-phase'),
        children: [
          Icon(_phaseIcon, size: 16, color: Aether.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _phase,
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ),
          if (expiry != null)
            Text(
              expiry,
              key: const ValueKey('mcp-oauth-expiry'),
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
            ),
        ],
      ),
    );
  }

  Widget _errorView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const AetherSectionTitle(
        eyebrow: 'Sign-in unavailable',
        subtitle: 'This server could not start a browser sign-in.',
      ),
      const SizedBox(height: 12),
      Text(
        _beginError ?? 'Unknown error',
        style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
      ),
      const SizedBox(height: 14),
      AetherPrimaryButton(
        label: 'Retry',
        icon: Icons.refresh,
        onPressed: _begin,
      ),
    ],
  );

  Widget _readyView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const AetherSectionTitle(
        eyebrow: 'Browser sign-in',
        subtitle:
            'Sign in on the page that opens. Ovid finishes automatically '
            'when the page sends you back here.',
      ),
      if (_notice != null) ...[
        const SizedBox(height: 10),
        Text(
          _notice!,
          key: const ValueKey('mcp-oauth-notice'),
          style: TextStyle(fontSize: 12.5, color: Aether.accent),
        ),
      ],
      const SizedBox(height: 14),
      AetherPrimaryButton(
        key: const ValueKey('mcp-oauth-open-browser'),
        label: 'Open sign-in page',
        icon: Icons.open_in_new,
        loading: _completing,
        onPressed: _completing ? null : _openBrowser,
      ),
      if (_callbackError != null) ...[
        const SizedBox(height: 10),
        Text(
          _callbackError!,
          key: const ValueKey('mcp-oauth-error'),
          style: TextStyle(fontSize: 12, color: Aether.danger),
        ),
      ],
      const SizedBox(height: 8),
      if (!_showPaste)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('mcp-oauth-show-paste'),
            onPressed: () => setState(() => _showPaste = true),
            child: const Text('Having trouble? Paste the address instead'),
          ),
        )
      else
        ..._pasteFallback(),
    ],
  );

  List<Widget> _pasteFallback() => [
    const SizedBox(height: 8),
    Text(
      'After you sign in, the browser may show an error or blank page — '
      "that's expected. Copy the address from the address bar and paste "
      'it here.',
      style: TextStyle(fontSize: 12, color: Aether.textMuted),
    ),
    const SizedBox(height: 10),
    _CopyableUrl(
      url: _authorizationUrl ?? '',
      copied: _copied,
      onCopy: () async {
        await Clipboard.setData(ClipboardData(text: _authorizationUrl ?? ''));
        if (mounted) setState(() => _copied = true);
      },
    ),
    const SizedBox(height: 12),
    AetherField(
      label: 'Address after sign-in',
      hint: 'Paste the full address from the browser',
      controller: _callbackController,
      maxLines: 3,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      fieldKey: const ValueKey('mcp-oauth-callback-field'),
      suffix: IconButton(
        key: const ValueKey('mcp-oauth-paste'),
        tooltip: 'Paste',
        icon: const Icon(Icons.content_paste, size: 18),
        onPressed: _pasteFromClipboard,
      ),
      onChanged: (_) {
        if (_callbackError != null) setState(() => _callbackError = null);
      },
    ),
    const SizedBox(height: 14),
    AetherPrimaryButton(
      key: const ValueKey('mcp-oauth-complete'),
      label: _completing ? 'Finishing…' : 'Finish sign-in',
      icon: Icons.check,
      loading: _completing,
      onPressed: _completing ? null : _complete,
    ),
  ];
}

class _CopyableUrl extends StatelessWidget {
  const _CopyableUrl({
    required this.url,
    required this.copied,
    required this.onCopy,
  });

  final String url;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => AetherCard(
    padding: const EdgeInsets.all(12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(
            url,
            semanticsLabel: 'Selectable sign-in link',
            maxLines: 4,
            style: AetherType.mono,
          ),
        ),
        IconButton(
          tooltip: copied ? 'Copied' : 'Copy sign-in link',
          onPressed: onCopy,
          icon: Icon(copied ? Icons.check : Icons.copy_outlined),
        ),
      ],
    ),
  );
}
