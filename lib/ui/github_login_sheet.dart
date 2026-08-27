import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/theme.dart';
import '../core/github_service.dart';
import 'browser_screen.dart';

/// GitHub login flow — shown as modal bottom sheet.
/// Implements OAuth Device Flow (RFC 8628).
///
/// States: idle → codeShown → polling → done
void showGithubLoginSheet(
  BuildContext context, {
  void Function()? onConnected,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Aether.surface,
    isScrollControlled: true,
    isDismissible: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _GithubLoginSheet(),
  ).then((ok) {
    if (ok == true && onConnected != null) onConnected();
  });
}

class _GithubLoginSheet extends StatefulWidget {
  const _GithubLoginSheet();

  @override
  State<_GithubLoginSheet> createState() => _GithubLoginSheetState();
}

class _GithubLoginSheetState extends State<_GithubLoginSheet> {
  _State _state = _State.idle;
  String _userCode = '';
  String _verifyUri = '';
  int _attempt = 0;
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
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _state = _State.starting);
    _cancelled = false;
    _attempt = 0;
    _error = null;
    _expiryTimer?.cancel();
    try {
      final authorization = await GitHubService.I.startDeviceFlow();
      if (!mounted || _cancelled) return;
      _userCode = authorization.userCode;
      _verifyUri = authorization.verificationUri.toString();
      _expiresAt = DateTime.now().add(authorization.expiresIn);
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
        isCancelled: () => _cancelled,
        onAttempt: (attempt) {
          if (mounted) setState(() => _attempt = attempt);
        },
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

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 18),
            switch (_state) {
              _State.idle || _State.starting => _startingView(),
              _State.codeShown => _codeView(),
              _State.done => _doneView(),
              _State.expired => _expiredView(),
              _State.error => _errorView(),
            },
          ],
        ),
      ),
    );
  }

  Widget _header() => Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: Aether.hairlineStrong),
            ),
            child: const Icon(Icons.hub_outlined, size: 22, color: Aether.text),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              'Connect GitHub',
              style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: Aether.textFaint),
            onPressed: () {
              _cancelled = true;
              _expiryTimer?.cancel();
              Navigator.pop(context);
            },
          ),
        ],
      );

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
        children: [
          const Text(
            'Open github.com/login/device on any browser and enter this code:',
            style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.accent.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SelectableText(
                  _userCode,
                  style: TextStyle(
                    fontFamily: Aether.mono,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 4,
                    color: Aether.accent,
                  ),
                ),
                const SizedBox(width: 12),
                _CopyChip(text: _userCode),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Aether.text,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    side: const BorderSide(color: Aether.hairlineStrong),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text(
                    'Open github.com/login/device',
                    style: TextStyle(fontSize: 12),
                  ),
                  onPressed: () async {
                    final uri = Uri.parse(
                      _verifyUri.isEmpty
                          ? 'https://github.com/login/device'
                          : _verifyUri,
                    );
                    if (!context.mounted) return;
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BrowserScreen(
                          initialUrl: uri.toString(),
                          agentControlled: false,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
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
              Text(
                'Waiting · $_remaining remaining · poll #$_attempt',
                style: const TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      );

  Widget _doneView() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Column(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: Aether.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border:
                    Border.all(color: Aether.success.withValues(alpha: 0.5)),
              ),
              child: const Icon(
                Icons.check_rounded,
                size: 30,
                color: Aether.success,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'GitHub connected',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              GitHubService.I.login != null
                  ? '@${GitHubService.I.login} — repos ready in Studio'
                  : 'Your repos are now accessible.',
              style: const TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );

  Widget _expiredView() => Column(
        children: [
          const Icon(Icons.timer_off_outlined, size: 36, color: Aether.warn),
          const SizedBox(height: 12),
          const Text(
            'Code expired',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'The device code expired. Try again.',
            style: TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _start,
            style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            child: const Text('Retry'),
          ),
        ],
      );

  Widget _errorView() => Column(
        children: [
          const Icon(Icons.error_outline, size: 36, color: Aether.danger),
          const SizedBox(height: 12),
          const Text(
            'Something went wrong',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _error ?? 'Unknown error',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _start,
            style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            child: const Text('Retry'),
          ),
        ],
      );
}

enum _State { idle, starting, codeShown, done, expired, error }

class _CopyChip extends StatefulWidget {
  final String text;
  const _CopyChip({required this.text});
  @override
  State<_CopyChip> createState() => _CopyChipState();
}

class _CopyChipState extends State<_CopyChip> {
  bool copied = false;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.text));
        setState(() => copied = true);
        Future.delayed(const Duration(seconds: 2), () {
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
              color: copied ? Aether.success : Aether.textFaint,
            ),
            const SizedBox(width: 5),
            Text(
              copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 10.5,
                color: copied ? Aether.success : Aether.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
