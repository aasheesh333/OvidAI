import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

// ─────────────────────────────────────────────────────────────────────────
// Unified connect-account pattern
//
// One calm scaffold shared by every "connect an account" sheet — MCP OAuth
// below and the GitHub device flow in github_login_sheet.dart. The scaffold
// owns the layout: title, provider eyebrow, code chip + copy, countdown,
// open-in-browser, paste-back field, and ONE primary action per state.
// Services keep their PKCE/device-flow logic; everything here is pure UI.
// ─────────────────────────────────────────────────────────────────────────

/// The five designed states of the unified connect-account pattern.
///
/// [waiting] covers both "starting" (a quiet spinner) and "waiting for the
/// user in the browser" (code chip + countdown). [verifying] is the brief
/// service round-trip after the user commits. [done], [error] and [expired]
/// are terminal states rendered by [ConnectAccountResult].
enum ConnectAccountPhase { waiting, verifying, done, error, expired }

/// Terminal-state content for the scaffold: a quiet tinted badge, one line
/// of context, and one primary action (Continue / Retry).
class ConnectAccountResult {
  const ConnectAccountResult({
    required this.icon,
    required this.color,
    required this.title,
    required this.actionLabel,
    required this.onAction,
    this.message,
    this.actionIcon,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? message;
  final String actionLabel;
  final IconData? actionIcon;
  final VoidCallback onAction;
}

/// Shared body scaffold for the connect-account sheets.
///
/// Each sheet keeps its own [AetherSheet] chrome (title + Cancel ghost) and
/// composes this widget as the body, so the whole connect-account surface is
/// one calm pattern. Layout of the active ([ConnectAccountPhase.waiting]/
/// [verifying]) body, top to bottom; every slot is optional so each flow
/// renders only what its service contract offers:
///
///  1. provider eyebrow + one calm instruction line ([provider], [status])
///  2. code chip — the server-issued code or authorization URL, display-only
///     — with the copy action on a row beneath it ([codeController],
///     [copyText])
///  3. open-in-browser ([onOpenBrowser]): stands alone as the one primary
///     when the flow completes itself (device flow); otherwise it pairs with
///     the primary as the secondary half of the bottom action row
///  4. countdown + waiting indicator ([countdown])
///  5. paste-back field ([callbackController]) — the deep-link fallback: a
///     platform redirect can deliver the callback straight to the sheet's
///     completion path, this field is the manual route when no link arrives
///  6. the action row: [onOpenBrowser] + [primaryLabel] side by side when
///     both exist, the lone primary otherwise — one primary per state
///
/// Terminal states pass a [result] instead; [loading] shows the spinner.
class ConnectAccountScaffold extends StatelessWidget {
  const ConnectAccountScaffold({
    super.key,
    this.loading = false,
    this.result,
    this.provider,
    this.status,
    this.codeLabel,
    this.codeController,
    this.codeFieldKey,
    this.codeMaxLines = 1,
    this.copyText,
    this.countdown,
    this.openBrowserLabel,
    this.openBrowserKey,
    this.onOpenBrowser,
    this.callbackLabel,
    this.callbackHint,
    this.callbackController,
    this.callbackFieldKey,
    this.callbackError,
    this.onCallbackChanged,
    this.primaryLabel,
    this.primaryKey,
    this.primaryIcon,
    this.onPrimary,
    this.primaryLoading = false,
  });

  /// True while the flow is starting (no content yet): a quiet spinner.
  final bool loading;

  /// Terminal state (done/error/expired); replaces the active slots.
  final ConnectAccountResult? result;

  /// Provider eyebrow (rendered uppercase) + one calm instruction line.
  final String? provider;
  final String? status;

  /// Code chip: the server-issued code/URL in a display-only field.
  final String? codeLabel;
  final TextEditingController? codeController;
  final Key? codeFieldKey;
  final int? codeMaxLines;

  /// Text the copy chip places on the clipboard; null hides the chip.
  final String? copyText;

  /// Formatted `m:ss` still available to finish the flow; renders the
  /// waiting row while the flow watches for completion.
  final String? countdown;

  /// 'Open in browser' action. Rendered as the primary button when the flow
  /// has no separate [primaryLabel], as a secondary button otherwise — the
  /// one-primary-per-state rule holds either way.
  final String? openBrowserLabel;
  final Key? openBrowserKey;
  final VoidCallback? onOpenBrowser;

  /// Paste-back field — the deep-link fallback for the callback URI.
  final String? callbackLabel;
  final String? callbackHint;
  final TextEditingController? callbackController;
  final Key? callbackFieldKey;
  final String? callbackError;
  final ValueChanged<String>? onCallbackChanged;

  /// The single primary action of the active state (e.g. 'Complete').
  final String? primaryLabel;
  final Key? primaryKey;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;
  final bool primaryLoading;

  @override
  Widget build(BuildContext context) {
    return result != null
        ? _ConnectAccountResultView(result: result!)
        : loading
        ? const _ConnectAccountSpinner()
        : _activeBody();
  }

  Widget _activeBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (provider != null) ...[
          AetherSectionTitle(eyebrow: provider!, subtitle: status),
          const SizedBox(height: 12),
        ],
        if (codeController != null) ...[
          AetherField(
            label: codeLabel ?? 'Code',
            controller: codeController,
            enabled: false,
            maxLines: codeMaxLines,
            fieldKey: codeFieldKey,
          ),
          if (copyText != null) ...[
            const SizedBox(height: 8),
            // The display-only code keeps its full content width; the copy
            // action rides its own right-aligned row beneath the field.
            Align(
              alignment: Alignment.centerRight,
              child: ConnectAccountCopyChip(text: copyText!),
            ),
          ],
          const SizedBox(height: 12),
        ],
        if (onOpenBrowser != null && primaryLabel == null) ...[
          // The flow completes itself (device flow): the browser step stands
          // alone as the one primary action of the waiting state.
          AetherPrimaryButton(
            key: openBrowserKey,
            label: openBrowserLabel ?? 'Open in browser',
            icon: Icons.open_in_new,
            onPressed: onOpenBrowser,
          ),
          const SizedBox(height: 16),
        ],
        if (countdown != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: Aether.accent,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  'Waiting · $countdown remaining',
                  style: AetherType.bodyMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (callbackController != null) ...[
          AetherField(
            label: callbackLabel ?? 'Callback URL',
            hint: callbackHint,
            controller: callbackController,
            maxLines: 3,
            fieldKey: callbackFieldKey,
            errorText: callbackError,
            onChanged: onCallbackChanged,
          ),
          const SizedBox(height: 14),
        ],
        if (onOpenBrowser != null && primaryLabel != null)
          // The flow has a manual completion step: one calm action row with
          // the browser step as its secondary half and a single primary.
          Row(
            children: [
              Expanded(
                child: AetherSecondaryButton(
                  key: openBrowserKey,
                  label: openBrowserLabel ?? 'Open in browser',
                  icon: Icons.open_in_new,
                  onPressed: onOpenBrowser,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AetherPrimaryButton(
                  key: primaryKey,
                  label: primaryLabel!,
                  icon: primaryIcon,
                  loading: primaryLoading,
                  onPressed: onPrimary,
                ),
              ),
            ],
          )
        else if (primaryLabel != null)
          AetherPrimaryButton(
            key: primaryKey,
            label: primaryLabel!,
            icon: primaryIcon,
            loading: primaryLoading,
            onPressed: onPrimary,
          ),
      ],
    );
  }
}

/// Quiet starting state shared by both sheets.
class _ConnectAccountSpinner extends StatelessWidget {
  const _ConnectAccountSpinner();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

/// Done/error/expired: one tinted badge, one line of context, one action.
class _ConnectAccountResultView extends StatelessWidget {
  const _ConnectAccountResultView({required this.result});

  final ConnectAccountResult result;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: result.color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: result.color.withValues(alpha: 0.5)),
            ),
            child: Icon(result.icon, size: 30, color: result.color),
          ),
          const SizedBox(height: 14),
          Text(result.title, style: AetherType.title),
          if (result.message != null) ...[
            const SizedBox(height: 4),
            Text(
              result.message!,
              textAlign: TextAlign.center,
              style: AetherType.bodyMuted,
            ),
          ],
          const SizedBox(height: 16),
          AetherPrimaryButton(
            label: result.actionLabel,
            icon: result.actionIcon,
            onPressed: result.onAction,
          ),
        ],
      ),
    );
  }
}

/// Code-chip copy action shared by the connect-account sheets. Shows
/// 'Copy' → 'Copied' for two seconds after a successful clipboard write.
class ConnectAccountCopyChip extends StatefulWidget {
  const ConnectAccountCopyChip({super.key, required this.text});

  final String text;

  @override
  State<ConnectAccountCopyChip> createState() => _ConnectAccountCopyChipState();
}

class _ConnectAccountCopyChipState extends State<ConnectAccountCopyChip> {
  bool copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 44dp minimum target (the repo-wide touch invariant): the chip used to
    // measure ~24dp, which is a mis-tap magnet next to the code it copies.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: () async {
          try {
            await Clipboard.setData(ClipboardData(text: widget.text));
          } catch (_) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Could not copy code. Please retry.'),
              ),
            );
            return;
          }
          if (!mounted) return;
          setState(() => copied = true);
          _resetTimer?.cancel();
          _resetTimer = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => copied = false);
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Aether.surfaceRaised,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                copied ? Icons.check : Icons.copy_outlined,
                size: 13,
                color: copied ? Aether.successLight : Aether.textFaint,
              ),
              const SizedBox(width: 5),
              Semantics(
                button: true,
                label: copied ? 'Code copied' : 'Copy code',
                child: Text(
                  copied ? 'Copied' : 'Copy',
                  style: TextStyle(
                    fontSize: 12,
                    color: copied ? Aether.successLight : Aether.textFaint,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

/// MCP OAuth on the unified [ConnectAccountScaffold]: the authorization URL
/// is the code chip, the paste-back field accepts the full callback URL, and
/// 'Complete' is the single primary action.
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
  State<McpOAuthSheet> createState() => McpOAuthSheetState();
}

/// Public state so a platform deep link can reach [completeWithCallback]
/// through a `GlobalKey<McpOAuthSheetState>`.
class McpOAuthSheetState extends State<McpOAuthSheet> {
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

  Future<void> _complete([String? callbackUri]) async {
    final callback = (callbackUri ?? _callbackController.text).trim();
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

  /// Deep-link entry point: when a platform redirect (e.g. an ovid://
  /// callback) delivers the full callback URI, hand it straight in here —
  /// the exact path the paste-back field uses. The field stays as the
  /// fallback when no deep link arrives.
  Future<void> completeWithCallback(String callbackUri) =>
      _complete(callbackUri);

  void _cancel() {
    widget.service.cancelAuthorization(widget.serverKey);
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    return AetherSheet(
      title: 'Connect ${widget.serverName}',
      actions: [
        AetherGhostButton(
          key: const ValueKey('mcp-oauth-cancel'),
          label: 'Cancel',
          onPressed: _completing ? null : _cancel,
        ),
      ],
      child: SingleChildScrollView(
        child: ConnectAccountScaffold(
          loading: _loading,
          result: _beginError != null
              ? ConnectAccountResult(
                  icon: Icons.error_outline,
                  color: Aether.danger,
                  title: 'Authorization unavailable',
                  message: _beginError,
                  actionLabel: 'Retry',
                  actionIcon: Icons.refresh,
                  onAction: _begin,
                )
              : null,
          provider: 'MCP OAuth',
          status: _completing
              ? 'Verifying the callback…'
              : 'Open the authorization page, sign in, then paste the full URL '
                    'the browser was redirected to.',
          codeLabel: 'Authorization URL',
          codeController: _authUrlController,
          codeFieldKey: const ValueKey('mcp-oauth-auth-url'),
          codeMaxLines: 3,
          copyText: _authorizationUrl,
          openBrowserLabel: 'Open in browser',
          openBrowserKey: const ValueKey('mcp-oauth-open-browser'),
          onOpenBrowser: _openBrowser,
          callbackLabel: 'Callback URL',
          callbackHint: 'Paste the full URL from the browser address bar',
          callbackController: _callbackController,
          callbackFieldKey: const ValueKey('mcp-oauth-callback-field'),
          callbackError: _callbackError,
          onCallbackChanged: (_) {
            if (_callbackError != null) setState(() => _callbackError = null);
          },
          primaryLabel: _completing ? 'Completing…' : 'Complete',
          primaryKey: const ValueKey('mcp-oauth-complete'),
          primaryIcon: Icons.check,
          primaryLoading: _completing,
          onPrimary: () => _complete(),
        ),
      ),
    );
  }
}
