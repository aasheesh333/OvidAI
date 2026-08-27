import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import '../core/github_service.dart';

/// GitHub login flow — shown as modal bottom sheet.
/// Implements OAuth Device Flow (RFC 8628).
///
/// States: idle → codeShown → polling → done
void showGithubLoginSheet(BuildContext context,
    {void Function()? onConnected}) {
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
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _state = _State.starting);
    try {
      final (code, uri, _, interval) =
          await GitHubService.I.startDeviceFlow();
      _userCode = code;
      _verifyUri = uri;
      setState(() => _state = _State.codeShown);
      _beginPolling(deviceCode: code, intervalSec: interval);
    } catch (e) {
      setState(() {
        _error = '$e';
        _state = _State.error;
      });
    }
  }

  void _beginPolling({required String deviceCode, required int intervalSec}) {
    _pollTimer = Timer.periodic(Duration(seconds: intervalSec), (_) async {
      setState(() => _attempt++);
      final res = await http.post(
        Uri.parse('https://github.com/login/oauth/access_token'),
        headers: {'Accept': 'application/json'},
        body: {
          'client_id': GitHubService.clientId,
          'device_code': deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body);
      if (body['access_token'] != null) {
        _pollTimer?.cancel();
        await GitHubService.I.fetchUser();
        setState(() => _state = _State.done);
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) Navigator.pop(context, true);
        });
      } else if (body['error'] == 'expired_token') {
        _pollTimer?.cancel();
        setState(() => _state = _State.expired);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 18, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 18),
            switch (_state) {
              _State.idle ||
              _State.starting =>
                _startingView(),
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

  Widget _header() => Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Aether.hairlineStrong),
          ),
          child: const Icon(Icons.hub_outlined,
              size: 22, color: Aether.text),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Text('Connect GitHub',
              style:
                  TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18, color: Aether.textFaint),
          onPressed: () {
            _pollTimer?.cancel();
            Navigator.pop(context);
          },
        ),
      ]);

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
                        borderRadius: BorderRadius.circular(11)),
                  ),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text('Open github.com/login/device',
                      style: TextStyle(fontSize: 12)),
                  onPressed: () async {
                    final uri = Uri.parse(_verifyUri.isEmpty
                        ? 'https://github.com/login/device'
                        : _verifyUri);
                    // can't launch url without a plugin — at least copy
                    await Clipboard.setData(ClipboardData(text: uri.toString()));
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
                child:
                    CircularProgressIndicator(strokeWidth: 1.8, color: Aether.accent),
              ),
              const SizedBox(width: 10),
              Text(
                'Waiting for authorization · poll #$_attempt',
                style: const TextStyle(
                    fontSize: 11.5, color: Aether.textFaint),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      );

  Widget _doneView() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Column(children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Aether.success.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                  color: Aether.success.withValues(alpha: 0.5)),
            ),
            child: const Icon(Icons.check_rounded,
                size: 30, color: Aether.success),
          ),
          const SizedBox(height: 14),
          const Text('GitHub connected',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            GitHubService.I.login != null
                ? '@${GitHubService.I.login} — repos ready in Studio'
                : 'Your repos are now accessible.',
            style: const TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
        ]),
      );

  Widget _expiredView() => Column(children: [
        const Icon(Icons.timer_off_outlined, size: 36, color: Aether.warn),
        const SizedBox(height: 12),
        const Text('Code expired',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text('The device code expired. Try again.',
            style: TextStyle(fontSize: 12, color: Aether.textMuted)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _start,
          style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11))),
          child: const Text('Retry'),
        ),
      ]);

  Widget _errorView() => Column(children: [
        const Icon(Icons.error_outline, size: 36, color: Aether.danger),
        const SizedBox(height: 12),
        const Text('Something went wrong',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(_error ?? 'Unknown error',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Aether.textMuted)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _start,
          style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11))),
          child: const Text('Retry'),
        ),
      ]);
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
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(copied ? Icons.check : Icons.copy_outlined,
              size: 13, color: copied ? Aether.success : Aether.textFaint),
          const SizedBox(width: 5),
          Text(copied ? 'Copied' : 'Copy',
              style: TextStyle(
                  fontSize: 10.5,
                  color: copied ? Aether.success : Aether.textFaint)),
        ]),
      ),
    );
  }
}

