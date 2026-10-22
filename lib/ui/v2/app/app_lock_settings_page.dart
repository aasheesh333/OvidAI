import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_lock.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'app_lock_sign_out.dart'
    if (dart.library.io) 'app_lock_sign_out_io.dart';

/// Settings surface for the app lock. The gate itself lives in
/// `app_lock_gate.dart`; this page only edits [AppLock].
///
/// New PINs are exactly six digits ([AppLock.isValidNewPin]). A four-digit PIN
/// set by an older build still verifies, so the "current PIN" prompt accepts
/// four to six digits.
///
/// When the stored secret is unreadable ([AppLock.recoveryRequired]) or the
/// cumulative failure cap was reached ([AppLock.reauthRequired]) the page
/// exposes the real recovery path: verify the account holder, then either
/// [AppLock.resetAfterReauth] (unreadable secret) or
/// [AppLock.completeAccountReauth] (keep the working PIN).
class AppLockSettingsPage extends StatefulWidget {
  const AppLockSettingsPage({
    super.key,
    this.lock,
    this.reauthenticate,
    this.signOut,
  });

  /// Test seam. Production uses [AppLock.I].
  final AppLock? lock;

  /// Proves the account holder is present before a recovery reset. The default
  /// uses the host's platform credential hook ([AppLock.biometric]); when the
  /// host supplied none, a fresh sign-out is the account re-authentication.
  final Future<bool> Function()? reauthenticate;

  /// Test seam for the sign-out fallback used by [reauthenticate].
  final Future<void> Function()? signOut;

  @override
  State<AppLockSettingsPage> createState() => _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends State<AppLockSettingsPage> {
  late final AppLock _lock = widget.lock ?? AppLock.I;
  bool _busy = false;

  bool get _blocked => _lock.recoveryRequired || _lock.reauthRequired;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_changed);
    _lock.load();
  }

  @override
  void dispose() {
    _lock.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _setPin({required bool change}) async {
    if (_blocked) {
      _snack('Reset the PIN before changing the app lock.');
      return;
    }
    final pin = await _askPin(
      title: change ? 'Change PIN' : 'Set a 6-digit PIN',
      isNew: true,
      confirm: true,
      description: change
          ? 'Choose a new 6-digit PIN.'
          : 'Choose a 6-digit PIN. You will enter it when Ovid comes back '
                'from the background.',
    );
    if (pin == null || !mounted) return;
    String? current;
    if (change && _lock.enabled) {
      current = await _askPin(
        title: 'Current PIN',
        isNew: false,
        confirm: false,
        description: 'Enter your existing PIN. PINs set by an older version '
            'may be 4–6 digits.',
      );
      if (current == null) return;
    }
    setState(() => _busy = true);
    final ok = await _lock.setPin(pin, currentPin: current);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _snack(_failureMessage());
    } else {
      _snack(change ? 'PIN updated.' : 'App lock is on.');
    }
  }

  String _failureMessage() {
    if (_lock.recoveryRequired || _lock.reauthRequired) {
      return 'Reset the PIN first.';
    }
    if (_lock.inCooldown) {
      final seconds = _lock.cooldownSecondsRemaining;
      return 'Too many attempts. Try again in ${seconds}s.';
    }
    return 'That PIN did not work. Nothing changed.';
  }

  Future<void> _disable() async {
    final pin = await _askPin(
      title: 'Enter your PIN',
      isNew: false,
      confirm: false,
      description: 'Enter your current PIN to turn the lock off.',
    );
    if (pin == null) return;
    final ok = await _lock.disable(pin);
    if (!mounted) return;
    _snack(ok ? 'App lock is off.' : _failureMessage());
  }

  /// Verifies the account holder, then clears the blocked state.
  ///
  /// An unreadable secret can only be replaced: [AppLock.resetAfterReauth]
  /// removes it so a new six-digit PIN can be set. A cumulative lockout keeps
  /// the working PIN and only clears the counters
  /// ([AppLock.completeAccountReauth]).
  Future<void> _recover() async {
    final recovery = _lock.recoveryRequired;
    final confirmed = await showOSheet<bool>(
      context,
      title: recovery ? 'Reset app lock PIN?' : 'Verify to use your PIN?',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                recovery
                    ? 'The saved PIN could not be read on this device. Verify '
                          'it is you to remove it, then set a new 6-digit PIN.'
                    : 'Too many wrong attempts were recorded. Verify it is you '
                          'to use your saved PIN again.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                'If this device has no biometric or screen lock, verifying '
                'signs you out so you can sign in again.',
                style: OType.caption.copyWith(color: c.textFaint),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Cancel',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                key: const ValueKey<String>('app-lock-confirm-reauth'),
                label: recovery ? 'Verify and reset' : 'Verify it’s me',
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final verified = await _reauthenticate();
    if (!verified) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Could not verify it is you. Nothing changed.');
      return;
    }

    // Clear the blocked state even if verifying signed the app out and
    // unmounted this page: the lock must not stay stuck after a re-auth.
    if (recovery) {
      final reset = await _lock.resetAfterReauth();
      if (!mounted) return;
      setState(() => _busy = false);
      if (!reset) {
        _snack('The PIN could not be reset. Try again.');
        return;
      }
      _snack('PIN reset. Set a new 6-digit PIN.');
      await _setPin(change: false);
    } else {
      await _lock.completeAccountReauth();
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('Verified. Your PIN works again.');
    }
  }

  Future<bool> _reauthenticate() async {
    final hook = widget.reauthenticate;
    if (hook != null) return hook();
    if (_lock.biometric != null) return _lock.unlockWithBiometrics();
    try {
      await (widget.signOut?.call() ?? defaultSignOut());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _askPin({
    required String title,
    required bool isNew,
    required bool confirm,
    String? description,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PinDialog(
        title: title,
        isNew: isNew,
        confirm: confirm,
        description: description,
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = _lock.enabled;
    return OScaffold(
      appBar: const OAppBar(title: 'App lock'),
      body: !_lock.loaded
          ? const OFadeSlide(child: OSkeletonList(rows: 4))
          : OFadeSlide(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.screen,
                  OSpace.l,
                  OSpace.screen,
                  OSpace.xxl,
                ),
                children: [
                  if (_blocked) ...[
                    _recoveryCard(context),
                    const SizedBox(height: OSpace.l),
                  ],
                  OCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Require a PIN',
                                style: OType.bodyStrong.copyWith(color: c.text),
                              ),
                              const SizedBox(height: OSpace.xs),
                              Text(
                                _blocked
                                    ? 'Reset the PIN before changing the lock.'
                                    : 'Ask for a 6-digit PIN when Ovid comes '
                                          'back to the foreground after a '
                                          'break.',
                                style: OType.caption.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: OSpace.m),
                        Switch.adaptive(
                          key: const ValueKey<String>('app-lock-switch'),
                          value: enabled,
                          onChanged: _busy || _blocked
                              ? null
                              : (value) {
                                  if (value) {
                                    _setPin(change: false);
                                  } else {
                                    _disable();
                                  }
                                },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: OSpace.l),
                  OCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        OListRow(
                          key: const ValueKey<String>('app-lock-change-pin'),
                          title: 'Change PIN',
                          subtitle: _blocked
                              ? 'Reset the PIN first'
                              : 'New PINs are exactly 6 digits',
                          icon: Icons.pin_outlined,
                          enabled: enabled && !_blocked && !_busy,
                          onTap: enabled && !_blocked && !_busy
                              ? () => _setPin(change: true)
                              : null,
                        ),
                        Divider(height: 1, thickness: 1, color: c.hairline),
                        OListRow(
                          key: const ValueKey<String>('app-lock-lock-after'),
                          title: 'Lock after',
                          subtitle: _lock.lockAfter.inMinutes >= 1
                              ? '${_lock.lockAfter.inMinutes} minutes in the background'
                              : 'Immediately in the background',
                          icon: Icons.timer_outlined,
                          trailing: OPill(
                            label: '${_lock.lockAfter.inMinutes} min',
                          ),
                          showChevron: false,
                          enabled: enabled && !_blocked && !_busy,
                          onTap: enabled && !_blocked && !_busy
                              ? _pickTimeout
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: OSpace.l),
                  Text(
                    'The PIN is stored as a salted hash on this device only. '
                    'It is never sent to Ovid and never appears in your chats.',
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _recoveryCard(BuildContext context) {
    final c = OColors.of(context);
    final recovery = _lock.recoveryRequired;
    return Container(
      key: const ValueKey<String>('app-lock-recovery-card'),
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_reset_rounded, size: 20, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  recovery ? 'PIN reset required' : 'PIN locked',
                  style: OType.h3.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(
            recovery
                ? 'The saved PIN could not be read on this device. Verify it '
                      'is you, then set a new 6-digit PIN.'
                : 'Too many wrong attempts. Verify it is you to use your PIN '
                      'again.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            key: const ValueKey<String>('app-lock-reset-pin'),
            label: recovery ? 'Reset PIN' : 'Verify it’s me',
            icon: Icons.verified_user_outlined,
            variant: OButtonVariant.secondary,
            expand: true,
            loading: _busy,
            onPressed: _busy ? null : _recover,
          ),
        ],
      ),
    );
  }

  Future<void> _pickTimeout() async {
    const options = <int>[0, 1, 2, 5, 15];
    final chosen = await showOSheet<int>(
      context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(OSpace.l),
              child: Text('Lock after'),
            ),
            for (final minutes in options)
              OListRow(
                title: minutes == 0 ? 'Immediately' : '$minutes minutes',
                trailing: _lock.lockAfter.inMinutes == minutes
                    ? const Icon(Icons.check_rounded)
                    : null,
                showChevron: false,
                onTap: () => Navigator.pop(sheetContext, minutes),
              ),
            const SizedBox(height: OSpace.s),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await _lock.setLockAfter(Duration(minutes: chosen));
  }
}

/// PIN entry dialog that validates before it can be submitted.
///
/// [isNew] enforces exactly six digits; the legacy current-PIN path accepts
/// four to six so a PIN from an older build can still be entered.
class _PinDialog extends StatefulWidget {
  const _PinDialog({
    required this.title,
    required this.isNew,
    required this.confirm,
    this.description,
  });

  final String title;
  final bool isNew;
  final bool confirm;
  final String? description;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  String get _pin => _first.text.trim();

  bool get _firstValid =>
      widget.isNew ? AppLock.isValidNewPin(_pin) : AppLock.isValidPin(_pin);

  bool get _matches => !widget.confirm || _second.text.trim() == _pin;

  bool get _valid => _firstValid && _matches;

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(_pin);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final mismatch =
        widget.confirm &&
        _second.text.isNotEmpty &&
        _second.text.trim() != _pin;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.description != null) ...[
              Text(
                widget.description!,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.m),
            ],
            TextField(
              key: const ValueKey<String>('app-lock-pin-field'),
              controller: _first,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: widget.confirm
                  ? TextInputAction.next
                  : TextInputAction.done,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: AppLock.pinLength,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (!widget.confirm) _submit();
              },
              decoration: InputDecoration(
                labelText: widget.isNew
                    ? '6-digit PIN'
                    : 'Current PIN (4–6 digits)',
                counterText: '',
              ),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: OSpace.s),
              TextField(
                key: const ValueKey<String>('app-lock-pin-confirm-field'),
                controller: _second,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: AppLock.pinLength,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Repeat 6-digit PIN',
                  counterText: '',
                  errorText: mismatch ? 'PINs do not match' : null,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey<String>('app-lock-pin-save'),
          onPressed: _valid ? _submit : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
