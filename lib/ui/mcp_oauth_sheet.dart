import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Opens a URL in the user's external browser. Injectable so widget tests can
/// observe the exact authorization URL the sheet hands to the platform.
typedef McpOAuthLauncher = Future<bool> Function(Uri uri);

/// Thin seam over the browser OAuth flow. The sheet only needs the
/// authorization URL, the full callback URI, and cancellation, so the service
/// keeps ownership of its attempt/state/PKCE material. Production wires the
/// [McpService] implementation at the composition root (see plugins_screen).
abstract class McpOAuthService {
  /// Begin a fresh authorization attempt and return the URL to open.
  Future<String> beginAuthorization(String serverKey);

  /// Complete the attempt with the FULL callback URI pasted by the user.
  Future<void> completeAuthorization(String serverKey, String callbackUri);

  /// Discard the pending attempt for [serverKey].
  void cancelAuthorization(String serverKey);
}

/// Launches [uri] in the external browser (never the in-app WebView).
Future<bool> defaultMcpOAuthLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Present the browser-based MCP OAuth sheet. Pops `true` after a successful
/// completion and `false` on cancel.
Future<bool?> showMcpOAuthSheet(
  BuildContext context, {
  required String serverKey,
  required String serverName,
  required McpOAuthService service,
  McpOAuthLauncher launcher = defaultMcpOAuthLauncher,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => McpOAuthSheet(
      serverKey: serverKey,
      serverName: serverName,
      service: service,
      launcher: launcher,
    ),
  );
}

/// Aether-primitive OAuth sheet: shows the authorization URL, opens it in the
/// browser, and accepts the full callback URL to complete the exchange.
class McpOAuthSheet extends StatefulWidget {
  const McpOAuthSheet({
    super.key,
    required this.serverKey,
    required this.serverName,
    required this.service,
    this.launcher = defaultMcpOAuthLauncher,
  });

  final String serverKey;
  final String serverName;
  final McpOAuthService service;
  final McpOAuthLauncher launcher;

  @override
  State<McpOAuthSheet> createState() => _McpOAuthSheetState();
}

class _McpOAuthSheetState extends State<McpOAuthSheet> {
  final _authUrlController = TextEditingController();
  final _callbackController = TextEditingController();
  bool _loading = true;
  bool _completing = false;
  String? _authorizationUrl;
  String? _beginError;
  String? _callbackError;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _authUrlController.dispose();
    _callbackController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _loading = true;
      _beginError = null;
    });
    try {
      final url = await widget.service.beginAuthorization(widget.serverKey);
      if (!mounted) return;
      _authUrlController.text = url;
      setState(() {
        _authorizationUrl = url;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _beginError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openBrowser() async {
    final url = _authorizationUrl;
    if (url == null) return;
    var launched = false;
    try {
      launched = await widget.launcher(Uri.parse(url));
    } catch (_) {
      launched = false;
    }
    if (!mounted || launched) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open the browser.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _complete() async {
    final callback = _callbackController.text.trim();
    if (callback.isEmpty) {
      setState(
        () => _callbackError = 'Paste the full callback URL from the browser.',
      );
      return;
    }
    setState(() {
      _completing = true;
      _callbackError = null;
    });
    try {
      await widget.service.completeAuthorization(widget.serverKey, callback);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _completing = false;
        _callbackError = 'Could not complete authorization: $e';
      });
    }
  }

  void _cancel() {
    widget.service.cancelAuthorization(widget.serverKey);
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    return AetherSheet(
      title: 'Authorize ${widget.serverName}',
      actions: [
        AetherGhostButton(
          key: const ValueKey('mcp-oauth-cancel'),
          label: 'Cancel',
          onPressed: _completing ? null : _cancel,
        ),
      ],
      child: SingleChildScrollView(
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            : _beginError != null
            ? _errorView()
            : _readyView(),
      ),
    );
  }

  Widget _errorView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const AetherSectionTitle(
        eyebrow: 'OAuth unavailable',
        subtitle: 'This server could not start a browser authorization.',
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
        eyebrow: 'Browser authorization',
        subtitle:
            'Open the authorization page, sign in, then paste the full URL '
            'the browser was redirected to.',
      ),
      const SizedBox(height: 14),
      AetherField(
        label: 'Authorization URL',
        controller: _authUrlController,
        enabled: false,
        maxLines: 3,
        fieldKey: const ValueKey('mcp-oauth-auth-url'),
      ),
      const SizedBox(height: 12),
      AetherPrimaryButton(
        key: const ValueKey('mcp-oauth-open-browser'),
        label: 'Open browser',
        icon: Icons.open_in_new,
        onPressed: _openBrowser,
      ),
      const SizedBox(height: 16),
      AetherField(
        label: 'Callback URL',
        hint: 'Paste the full URL from the browser address bar',
        controller: _callbackController,
        maxLines: 3,
        fieldKey: const ValueKey('mcp-oauth-callback-field'),
        onChanged: (_) {
          if (_callbackError != null) setState(() => _callbackError = null);
        },
      ),
      if (_callbackError != null) ...[
        const SizedBox(height: 8),
        Text(
          _callbackError!,
          style: TextStyle(fontSize: 12, color: Aether.danger),
        ),
      ],
      const SizedBox(height: 14),
      AetherPrimaryButton(
        key: const ValueKey('mcp-oauth-complete'),
        label: _completing ? 'Completing…' : 'Complete',
        icon: Icons.check,
        loading: _completing,
        onPressed: _completing ? null : _complete,
      ),
    ],
  );
}
