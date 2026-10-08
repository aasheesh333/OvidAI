import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';
import '../core/github_service.dart';
import 'widgets/aether_primitives.dart';

/// GitHub login flow — shown as an Aether modal bottom sheet.
/// Implements OAuth Device Flow (RFC 8628).
///
/// States: idle → codeShown → polling → done
void showGithubLoginSheet(
  BuildContext context, {
  void Function()? onConnected,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    builder: (_) => const GithubLoginSheet(),
  ).then((ok) {
    if (ok == true && onConnected != null) onConnected();
  });
}

class GithubLoginSheet extends StatefulWidget {
  const GithubLoginSheet({super.key, this.client});

  /// Optional HTTP client override for the device-flow requests. Production
  /// callers leave this null; widget tests inject a mock.
  final http.Client? client;

  @override
  State<GithubLoginSheet> createState() => _GithubLoginSheetState();
}

class _GithubLoginSheetState extends State<GithubLoginSheet> {
  _State _state = _State.idle;
  final _codeController = TextEditingController();
  String _userCode = '';
  String _verifyUri = '';
  String? _error;
  Timer? _expiryTimer;
  DateTime? _expiresAt;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cancelled = true;
    _expiryTimer?.cancel();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _state = _State.starting);
    _cancelled = false;
    _error = null;
    _expiryTimer?.cancel();
    try {
      final authorization = await GitHubService.I.startDeviceFlow(
        client: widget.client,
      );
      if (!mounted || _cancelled) return;
      _userCode = authorization.userCode;
      _verifyUri = authorization.verificationUri.toString();
      _expiresAt = DateTime.now().add(authorization.expiresIn);
      _codeController.text = _userCode;
      setState(() => _state = _State.codeShown);
      _expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      unawaited(_beginPolling(authorization));
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _error = '$e';
        _state = _State.error;
      });
    }
  }

  Future<void> _beginPolling(GitHubDeviceAuthorization authorization) async {
    try {
      await GitHubService.I.pollForToken(
        deviceCode: authorization.deviceCode,
        intervalSec: authorization.interval.inSeconds,
        maxWait: authorization.expiresIn,
        client: widget.client,
        isCancelled: () => _cancelled,
      );
      if (!mounted || _cancelled) return;
      _expiryTimer?.cancel();
      setState(() => _state = _State.done);
    } on GitHubAuthException catch (e) {
      if (!mounted || _cancelled || e.code == 'cancelled') return;
      _expiryTimer?.cancel();
      if (e.code == 'expired_token' || e.code == 'timeout') {
        setState(() => _state = _State.expired);
      } else {
        setState(() {
          _error = e.message;
          _state = _State.error;
        });
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      _expiryTimer?.cancel();
      setState(() {
        _error = '$e';
        _state = _State.error;
      });
    }
  }

  String get _remaining {
    final seconds = (_expiresAt?.difference(DateTime.now()).inSeconds ?? 0)
        .clamp(0, 60 * 60);
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _openVerificationPage() async {
    final uri = Uri.parse(
      _verifyUri.isEmpty ? 'https://github.com/login/device' : _verifyUri,
    );
    // Open in the user's EXTERNAL browser — the device-flow verification
    // page must not be trapped in the in-app WebView.
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched) return;
    } catch (_) {
      // Platform launch failures use the same recoverable browser message.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open the browser.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _cancel() {
    _cancelled = true;
    _expiryTimer?.cancel();
    // Polling observes _cancelled and exits at its next checkpoint.
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AetherSheet(
      title: 'Connect GitHub',
      actions: [AetherGhostButton(label: 'Cancel', onPressed: _cancel)],
      child: SingleChildScrollView(
        child: switch (_state) {
          _State.idle || _State.starting => _startingView(),
          _State.codeShown => _codeView(),
          _State.done => _doneView(),
          _State.expired => _expiredView(),
          _State.error => _errorView(),
        },
      ),
    );
  }

  Widget _startingView() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );

  Widget _codeView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const AetherSectionTitle(
        eyebrow: 'GitHub OAuth',
        subtitle:
            'Open github.com/login/device on any browser and enter this code:',
      ),
      const SizedBox(height: 14),
      // Keep the full server code visible at large text. The separate copy
      // action remains interactive while the server-issued field is disabled.
      AetherField(
        label: 'One-time code',
        controller: _codeController,
        enabled: false,
        maxLines: null,
      ),
      const SizedBox(height: 8),
      _UrlCopyRow(
        url: _verifyUri.isEmpty ? 'https://github.com/login/device' : _verifyUri,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: _CopyChip(text: _userCode, semanticsLabel: 'Copy code'),
      ),
      const SizedBox(height: 14),
      AetherPrimaryButton(
        label: 'Sign in',
        icon: Icons.open_in_new,
        onPressed: _openVerificationPage,
      ),
      const SizedBox(height: 16),
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
           child: Semantics(
             liveRegion: true,
             label: 'GitHub sign-in status: waiting, $_remaining remaining',
             child: Text(
               'Waiting for sign-in · $_remaining remaining',
               style: AetherType.bodyMuted,
             ),
           ),
          ),
        ],
      ),
      const SizedBox(height: 8),
    ],
  );

  Widget _doneView() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 22),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: Aether.successLight.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: Aether.successLight.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(
            Icons.check_rounded,
            size: 30,
            color: Aether.successLight,
          ),
        ),
        const SizedBox(height: 14),
        Text('GitHub connected', style: AetherType.title),
        const SizedBox(height: 4),
        Text(
          GitHubService.I.login != null
              ? '@${GitHubService.I.login} — repos ready in Studio'
              : 'Your repos are now accessible.',
          style: AetherType.bodyMuted,
        ),
        const SizedBox(height: 16),
        AetherPrimaryButton(
          label: 'Continue',
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );

  Widget _expiredView() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.timer_off_outlined, size: 36, color: Aether.warnLight),
      const SizedBox(height: 12),
      Text('Code expired', style: AetherType.title),
      const SizedBox(height: 4),
      Text('The device code expired. Try again.', style: AetherType.bodyMuted),
      const SizedBox(height: 16),
      AetherPrimaryButton(
        label: 'Retry',
        icon: Icons.refresh,
        onPressed: _start,
      ),
    ],
  );

  Widget _errorView() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.error_outline, size: 36, color: Aether.danger),
      const SizedBox(height: 12),
      Text('Something went wrong', style: AetherType.title),
      const SizedBox(height: 4),
      Text(
        _error ?? 'Unknown error',
        textAlign: TextAlign.center,
        style: AetherType.bodyMuted,
      ),
      const SizedBox(height: 16),
      AetherPrimaryButton(
        label: 'Retry',
        icon: Icons.refresh,
        onPressed: _start,
      ),
    ],
  );
}

enum _State { idle, starting, codeShown, done, expired, error }

class _CopyChip extends StatefulWidget {
  final String text;
  final String label;
  final String? semanticsLabel;
  const _CopyChip({
    required this.text,
    this.label = 'Copy',
    this.semanticsLabel,
  });
  @override
  State<_CopyChip> createState() => _CopyChipState();
}

class _UrlCopyRow extends StatelessWidget {
  const _UrlCopyRow({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) => AetherCard(
    padding: const EdgeInsets.all(12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Semantics(
            label: 'Verification URL. Selectable text.',
            child: SelectableText(url, style: AetherType.mono),
          ),
        ),
        const SizedBox(width: 8),
        _CopyChip(text: url, label: 'Copy URL'),
      ],
    ),
  );
}

class _CopyChipState extends State<_CopyChip> {
  bool copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantics = widget.semanticsLabel ?? widget.label;
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
              const SnackBar(content: Text('Could not copy code. Please retry.')),
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
                 label: copied ? '$semantics copied' : semantics,
                 child: Text(
                   copied ? 'Copied' : widget.label,
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
