import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';
import '../core/github_service.dart';
import 'studio_errors.dart';
import 'widgets/aether_primitives.dart';

/// GitHub login flow — shown as an Aether modal bottom sheet.
/// Implements OAuth Device Flow (RFC 8628).
///
/// States: idle → codeShown → polling → done
void showGithubLoginSheet(
  BuildContext context, {
  void Function()? onConnected,
}) {
  showAetherSheet<bool>(
    context: context,
    isDismissible: false,
    builder: (_) => const GithubLoginSheet(),
  ).then((ok) {
    if (ok == true && onConnected != null) onConnected();
  });
}

class GithubLoginSheet extends StatefulWidget {
  const GithubLoginSheet({super.key, this.client, this.waitForNextPoll});

  /// Optional HTTP client override for the device-flow requests. Production
  /// callers leave this null; widget tests inject a mock.
  final http.Client? client;
  final Future<void> Function(Duration interval)? waitForNextPoll;

  @override
  State<GithubLoginSheet> createState() => _GithubLoginSheetState();
}

class _GithubLoginSheetState extends State<GithubLoginSheet>
    with WidgetsBindingObserver {
  _State _state = _State.idle;
  final _codeController = TextEditingController();
  String _userCode = '';
  String _verifyUri = '';
  String? _error;
  String? _errorDetail;
  bool _showDetail = false;
  DateTime? _expiresAt;
  bool _cancelled = false;

  /// Polling pauses while the app is in the background (Android restricts
  /// network there; the user is approving in the browser) and polls at once
  /// on resume instead of waiting out the interval.
  bool _paused = false;
  Completer<void>? _wake;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelled = true;
    _wakePolling();
    _codeController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _paused = true;
        _pollTimer?.cancel();
        _pollTimer = null;
      case AppLifecycleState.resumed:
        _paused = false;
        _wakePolling();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  void _wakePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> _waitForNextPoll(Duration interval) {
    final wake = Completer<void>();
    _wake = wake;
    if (_cancelled) {
      wake.complete();
    } else if (!_paused) {
      _pollTimer = Timer(interval, () {
        if (!wake.isCompleted) wake.complete();
      });
    }
    return wake.future;
  }

  void _showError(Object e) {
    final f = StudioFailure.of(e);
    setState(() {
      _error = f.message;
      _errorDetail = f.detail;
      _showDetail = false;
      _state = _State.error;
    });
  }

  Future<void> _start() async {
    setState(() => _state = _State.starting);
    _cancelled = false;
    _error = null;
    _errorDetail = null;
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
      unawaited(_beginPolling(authorization));
    } catch (e) {
      if (!mounted || _cancelled) return;
      _showError(e);
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
        waitForNextPoll: widget.waitForNextPoll ?? _waitForNextPoll,
      );
      if (!mounted || _cancelled) return;
      setState(() => _state = _State.done);
    } on GitHubAuthException catch (e) {
      if (!mounted || _cancelled || e.code == 'cancelled') return;
      if (e.code == 'expired_token' || e.code == 'timeout') {
        setState(() => _state = _State.expired);
      } else {
        _showError(e);
      }
    } catch (e) {
      if (!mounted || _cancelled) return;
      _showError(e);
    }
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
    // Polling observes _cancelled and exits at its next checkpoint.
    _wakePolling();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AetherSheet(
      title: 'Connect GitHub',
      // Pin Cancel below the scrolling body: at 360x640 with textScale 2.0 the
      // code view is taller than the viewport, and a scrolling action row left
      // Cancel just below the fold and un-tappable.
      pinActions: true,
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
        url: _verifyUri.isEmpty
            ? 'https://github.com/login/device'
            : _verifyUri,
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
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: Aether.accent,
            ),
          ),
          const SizedBox(width: 10),
          // The live region only changes on state transitions: a per-second
          // countdown inside it made TalkBack speak every second for up to
          // 15 minutes. The countdown is excluded from semantics and only
          // announces at 5 and 1 minute left.
          Flexible(
            child: Semantics(
              key: githubLoginStatusKey,
              liveRegion: true,
              label:
                  'GitHub sign-in status: waiting for you to approve in '
                  'the browser',
              child: ExcludeSemantics(
                child: Text('Waiting for sign-in', style: AetherType.bodyMuted),
              ),
            ),
          ),
          if (_expiresAt != null)
            Flexible(child: _Countdown(expiresAt: _expiresAt!)),
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
            color: Aether.success.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(
              color: Aether.success.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(
            Icons.check_rounded,
            size: 30,
            color: Aether.success,
          ),
        ),
        const SizedBox(height: 14),
        Text('GitHub connected', style: AetherType.title),
        const SizedBox(height: 4),
        Text(
          GitHubService.I.login != null
              ? '@${GitHubService.I.login} — connected for this session'
              : 'Your GitHub account is connected for this session.',
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
      Icon(Icons.timer_off_outlined, size: 36, color: Aether.warn),
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
      Icon(Icons.error_outline, size: 36, color: Aether.danger),
      const SizedBox(height: 12),
      Text('Something went wrong', style: AetherType.title),
      const SizedBox(height: 4),
      Text(
        _error ?? 'GitHub sign-in did not finish. Try again.',
        textAlign: TextAlign.center,
        style: AetherType.bodyMuted,
      ),
      if ((_errorDetail ?? '').isNotEmpty && _errorDetail != _error) ...[
        const SizedBox(height: 4),
        AetherGhostButton(
          label: _showDetail ? 'Hide details' : 'Details',
          onPressed: () => setState(() => _showDetail = !_showDetail),
        ),
        if (_showDetail)
          SelectableText(
            _errorDetail!,
            textAlign: TextAlign.center,
            style: AetherType.mono.copyWith(color: Aether.textFaint),
          ),
      ],
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

/// The waiting-status live region (test seam).
@visibleForTesting
const Key githubLoginStatusKey = ValueKey('github-login-status');

/// Self-contained countdown: ticks only itself (not the whole sheet), is
/// hidden from semantics, and makes a polite announcement at 5 and 1 minute
/// remaining.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.expiresAt});
  final DateTime expiresAt;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Stream<int> _ticks;
  int? _lastAnnounced;

  @override
  void initState() {
    super.initState();
    _ticks = Stream<int>.periodic(
      const Duration(seconds: 1),
      (_) => _secondsLeft(),
    );
  }

  int _secondsLeft() =>
      widget.expiresAt.difference(DateTime.now()).inSeconds.clamp(0, 60 * 60);

  void _maybeAnnounce(int seconds) {
    for (final mark in const [300, 60]) {
      if (seconds <= mark && seconds > mark - 5 && _lastAnnounced != mark) {
        _lastAnnounced = mark;
        final view = View.maybeOf(context);
        if (view == null) return;
        unawaited(
          SemanticsService.sendAnnouncement(
            view,
            '${mark ~/ 60} minute${mark == 60 ? '' : 's'} left to approve '
            'GitHub sign-in',
            Directionality.of(context),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<int>(
    stream: _ticks,
    initialData: _secondsLeft(),
    builder: (context, snapshot) {
      final seconds = snapshot.data ?? 0;
      _maybeAnnounce(seconds);
      final text =
          ' · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} '
          'remaining';
      return ExcludeSemantics(child: Text(text, style: AetherType.bodyMuted));
    },
  );
}

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
                color: copied ? Aether.success : Aether.textFaint,
              ),
              const SizedBox(width: 5),
              Semantics(
                button: true,
                label: copied ? '$semantics copied' : semantics,
                child: Text(
                  copied ? 'Copied' : widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: copied ? Aether.success : Aether.textFaint,
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
