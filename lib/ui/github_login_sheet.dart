import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';
import '../core/github_service.dart';
import 'mcp_oauth_sheet.dart';
import 'widgets/aether_primitives.dart';

/// GitHub login flow — shown as an Aether modal bottom sheet on the unified
/// [ConnectAccountScaffold] shared with the MCP OAuth sheet.
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
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
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

  /// Terminal states of the unified pattern (done/error/expired); null while
  /// the sheet is starting or waiting on the user.
  ConnectAccountResult? get _result => switch (_state) {
    _State.done => ConnectAccountResult(
      icon: Icons.check_rounded,
      color: Aether.successLight,
      title: 'GitHub connected',
      message: GitHubService.I.login != null
          ? '@${GitHubService.I.login} — repos ready in Studio'
          : 'Your repos are now accessible.',
      actionLabel: 'Continue',
      onAction: () => Navigator.pop(context, true),
    ),
    _State.expired => ConnectAccountResult(
      icon: Icons.timer_off_outlined,
      color: Aether.warnLight,
      title: 'Code expired',
      message: 'The device code expired. Try again.',
      actionLabel: 'Retry',
      actionIcon: Icons.refresh,
      onAction: _start,
    ),
    _State.error => ConnectAccountResult(
      icon: Icons.error_outline,
      color: Aether.danger,
      title: 'Something went wrong',
      message: _error ?? 'Unknown error',
      actionLabel: 'Retry',
      actionIcon: Icons.refresh,
      onAction: _start,
    ),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    // The device flow completes itself by polling, so 'Sign in' (open in
    // browser) is the one primary action of the waiting state; the code
    // chip, copy action and countdown come from the shared scaffold.
    return AetherSheet(
      title: 'Connect GitHub',
      actions: [AetherGhostButton(label: 'Cancel', onPressed: _cancel)],
      child: SingleChildScrollView(
        child: ConnectAccountScaffold(
          loading: _state == _State.idle || _state == _State.starting,
          result: _result,
          provider: 'GitHub OAuth',
          status:
              'Open github.com/login/device on any browser and enter this code:',
          codeLabel: 'One-time code',
          codeController: _codeController,
          codeMaxLines: null,
          copyText: _userCode,
          countdown: _remaining,
          openBrowserLabel: 'Sign in',
          onOpenBrowser: _openVerificationPage,
        ),
      ),
    );
  }
}

enum _State { idle, starting, codeShown, done, expired, error }
