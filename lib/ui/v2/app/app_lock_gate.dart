import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../../../core/app_lock.dart';
import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

/// Covers the app with the PIN lock screen whenever [AppLock.locked] is true.
///
/// The child stays mounted (so chat drafts and scroll positions survive) but
/// is offstage and non-interactive while locked: no painting, no semantics and
/// no tickers. Unlocking restores it exactly where it was.
///
/// [AppLockGate] is also the lifecycle adapter: `paused` records the time the
/// app left the foreground, `resumed` locks when that was longer than
/// [AppLock.lockAfter]. `inactive` is ignored so system dialogs never trigger
/// the lock. Mount this inside `MaterialApp` (the theme supplies [OColors]).
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.child,
    this.lock,
    this.biometric,
    this.onSignOut,
    this.title = 'App locked',
    this.subtitle = 'Enter your PIN to continue.',
  });

  /// The protected subtree.
  final Widget child;

  /// Defaults to [AppLock.I]. Tests inject their own instance.
  final AppLock? lock;

  /// Optional platform authentication (biometric / device credential). The
  /// "Use biometrics" action renders only when this hook (or
  /// [AppLock.biometric]) is supplied.
  final BiometricCheck? biometric;

  /// Invoked by "Sign out instead". The host decides what signing out means;
  /// the lock never clears the account itself.
  final VoidCallback? onSignOut;

  final String title;
  final String subtitle;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  late AppLock _lock;
  Timer? _cooldownTimer;
  String _entry = '';
  String? _error;
  bool _checkingPin = false;
  bool _checkingBiometrics = false;

  @override
  void initState() {
    super.initState();
    _lock = widget.lock ?? AppLock.I;
    _lock.addListener(_onLockChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_lock.load());
    _syncCooldownTimer();
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lock != oldWidget.lock) {
      _lock.removeListener(_onLockChanged);
      _lock = widget.lock ?? AppLock.I;
      _lock.addListener(_onLockChanged);
      unawaited(_lock.load());
    }
    _syncCooldownTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_lock.handleLifecycleState(state));
  }

  @override
  void dispose() {
    _stopCooldownTimer();
    _lock.removeListener(_onLockChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onLockChanged() {
    if (!mounted) return;
    setState(() {
      if (!_lock.locked) {
        _entry = '';
        _error = null;
        _checkingPin = false;
        _checkingBiometrics = false;
      }
    });
    _syncCooldownTimer();
  }

  void _syncCooldownTimer() {
    if (_lock.inCooldown && _cooldownTimer == null) {
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (!_lock.inCooldown) _stopCooldownTimer();
      });
    } else if (!_lock.inCooldown) {
      _stopCooldownTimer();
    }
  }

  void _stopCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
  }

  void _append(String digit) {
    if (_lock.inCooldown || _entry.length >= 6) return;
    setState(() {
      _entry += digit;
      _error = null;
    });
  }

  void _backspace() {
    if (_entry.isEmpty) return;
    setState(() => _entry = _entry.substring(0, _entry.length - 1));
  }

  Future<void> _submit() async {
    if (_checkingPin || _lock.inCooldown || _entry.length < 4) return;
    final pin = _entry;
    setState(() {
      _checkingPin = true;
      _error = null;
    });
    final ok = await _lock.unlock(pin);
    if (!mounted) return;
    setState(() {
      _checkingPin = false;
      if (!ok) {
        _entry = '';
        _error = _lock.inCooldown ? null : 'Wrong PIN. Try again.';
      }
    });
    _syncCooldownTimer();
  }

  Future<void> _useBiometrics() async {
    final hook = widget.biometric ?? _lock.biometric;
    if (hook == null || _checkingBiometrics) return;
    setState(() {
      _checkingBiometrics = true;
      _error = null;
    });
    final ok = await _lock.unlockWithBiometrics(hook);
    if (!mounted) return;
    setState(() {
      _checkingBiometrics = false;
      if (!ok) _error = 'Biometrics did not match.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final locked = _lock.loaded && _lock.locked;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: !_lock.loaded || locked,
          child: TickerMode(
            enabled: _lock.loaded && !locked,
            child: widget.child,
          ),
        ),
        // Neutral surface while the persisted state is read: never flash the
        // protected content before we know whether the app is locked.
        if (!_lock.loaded) ColoredBox(color: c.bg),
        if (locked) Positioned.fill(child: _buildLockScreen(c)),
      ],
    );
  }

  Widget _buildLockScreen(OColors c) {
    final cooldown = _lock.inCooldown;
    final seconds = _lock.cooldownSecondsRemaining;
    final canSubmit = !cooldown && !_checkingPin && _entry.length >= 4;
    final hasBiometrics = (widget.biometric ?? _lock.biometric) != null;

    return PopScope(
      canPop: false,
      child: Material(
        color: c.bg,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final minHeight = constraints.maxHeight.isFinite
                  ? max(0.0, constraints.maxHeight - OSpace.xl * 2)
                  : 0.0;
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.l,
                  vertical: OSpace.xl,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              widget.title,
                              textAlign: TextAlign.center,
                              style: OType.h1.copyWith(color: c.text),
                            ),
                          ),
                          const SizedBox(height: OSpace.s),
                          Text(
                            widget.subtitle,
                            textAlign: TextAlign.center,
                            style: OType.bodySm.copyWith(color: c.textMuted),
                          ),
                          const SizedBox(height: OSpace.xl),
                          _PinDots(length: _entry.length, colors: c),
                          const SizedBox(height: OSpace.m),
                          _buildFeedback(
                            c,
                            cooldown: cooldown,
                            seconds: seconds,
                          ),
                          const SizedBox(height: OSpace.m),
                          _buildKeypad(c, enabled: !cooldown && !_checkingPin),
                          const SizedBox(height: OSpace.l),
                          OButton(
                            label: 'Unlock',
                            expand: true,
                            loading: _checkingPin,
                            onPressed: canSubmit ? _submit : null,
                          ),
                          if (hasBiometrics) ...[
                            const SizedBox(height: OSpace.s),
                            OButton(
                              label: 'Use biometrics',
                              icon: Icons.fingerprint_rounded,
                              variant: OButtonVariant.secondary,
                              expand: true,
                              loading: _checkingBiometrics,
                              onPressed: _checkingBiometrics
                                  ? null
                                  : _useBiometrics,
                            ),
                          ],
                          if (widget.onSignOut != null) ...[
                            const SizedBox(height: OSpace.s),
                            OButton(
                              label: 'Sign out instead',
                              variant: OButtonVariant.ghost,
                              expand: true,
                              onPressed: widget.onSignOut,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFeedback(
    OColors c, {
    required bool cooldown,
    required int seconds,
  }) {
    if (cooldown) {
      return Semantics(
        liveRegion: true,
        child: Text(
          'Too many attempts. Try again in ${seconds}s.',
          textAlign: TextAlign.center,
          style: OType.bodySm.copyWith(color: c.danger),
        ),
      );
    }
    final error = _error;
    if (error == null) return const SizedBox(height: OSpace.s);
    return Semantics(
      liveRegion: true,
      child: Text(
        error,
        textAlign: TextAlign.center,
        style: OType.bodySm.copyWith(color: c.danger),
      ),
    );
  }

  Widget _buildKeypad(OColors c, {required bool enabled}) {
    const rows = <List<String>>[
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'back'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Row(
            children: [
              for (final key in row)
                if (key.isEmpty)
                  const Expanded(child: SizedBox(height: OSpace.touch))
                else if (key == 'back')
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(OSpace.xs),
                      child: SizedBox(
                        height: OSpace.touch,
                        child: IconButton(
                          onPressed: enabled ? _backspace : null,
                          tooltip: 'Delete digit',
                          icon: const Icon(Icons.backspace_outlined),
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(OSpace.xs),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: OSpace.touch,
                        ),
                        child: OutlinedButton(
                          onPressed: enabled ? () => _append(key) : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, OSpace.touch),
                            padding: const EdgeInsets.symmetric(
                              vertical: OSpace.s,
                            ),
                            foregroundColor: c.text,
                            disabledForegroundColor: c.textFaint,
                            side: BorderSide(
                              color: enabled ? c.hairlineStrong : c.hairline,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(ORadius.m),
                            ),
                            textStyle: OType.h3,
                          ),
                          child: Text(key),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
      ],
    );
  }
}

/// Six slots: a 4-digit PIN leaves two empty, a 6-digit PIN fills them all.
class _PinDots extends StatelessWidget {
  const _PinDots({required this.length, required this.colors});

  final int length;
  final OColors colors;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'PIN entry, $length of 6 digits',
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 6; i++)
              AnimatedContainer(
                duration: OMotion.instant,
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < length ? colors.accentFill : Colors.transparent,
                  border: Border.all(
                    color: i < length
                        ? colors.accentFill
                        : colors.hairlineStrong,
                    width: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
