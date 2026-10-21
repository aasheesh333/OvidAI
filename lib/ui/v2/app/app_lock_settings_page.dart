import 'package:flutter/material.dart';

import '../../../core/app_lock.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// Settings surface for the app lock. The gate itself lives in
/// `app_lock_gate.dart`; this page only edits [AppLock].
class AppLockSettingsPage extends StatefulWidget {
  const AppLockSettingsPage({super.key, this.lock});

  /// Test seam. Production uses [AppLock.I].
  final AppLock? lock;

  @override
  State<AppLockSettingsPage> createState() => _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends State<AppLockSettingsPage> {
  late final AppLock _lock = widget.lock ?? AppLock.I;
  bool _busy = false;

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
    final pin = await _askPin(
      title: change ? 'Change PIN' : 'Set a PIN',
      confirm: true,
    );
    if (pin == null || !mounted) return;
    setState(() => _busy = true);
    String? current;
    if (change && _lock.enabled) {
      current = await _askPin(title: 'Current PIN', confirm: false);
      if (current == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    }
    final ok = await _lock.setPin(pin, currentPin: current);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _snack('That PIN did not match. Nothing changed.');
    } else {
      _snack(change ? 'PIN updated.' : 'App lock is on.');
    }
  }

  Future<void> _disable() async {
    final pin = await _askPin(title: 'Enter your PIN', confirm: false);
    if (pin == null) return;
    final ok = await _lock.disable(pin);
    if (!mounted) return;
    _snack(ok ? 'App lock is off.' : 'That PIN did not match.');
  }

  Future<String?> _askPin({
    required String title,
    required bool confirm,
  }) {
    final first = TextEditingController();
    final second = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              autofocus: true,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'PIN (4–6 digits)'),
            ),
            if (confirm)
              TextField(
                controller: second,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'Repeat PIN'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final a = first.text.trim();
              final b = second.text.trim();
              if (confirm && a != b) {
                Navigator.pop(dialogContext);
                return;
              }
              Navigator.pop(dialogContext, a);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(() {
      first.dispose();
      second.dispose();
    });
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
      body: OFadeSlide(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.screen,
            OSpace.l,
            OSpace.screen,
            OSpace.xxl,
          ),
          children: [
            OCard(
              child: Row(
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
                          'Ask for a PIN when Ovid comes back to the '
                          'foreground after a break.',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Switch.adaptive(
                    value: enabled,
                    onChanged: _busy
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
                    title: 'Change PIN',
                    icon: Icons.pin_outlined,
                    enabled: enabled,
                    onTap: enabled ? () => _setPin(change: true) : null,
                  ),
                  Divider(height: 1, thickness: 1, color: c.hairline),
                  OListRow(
                    title: 'Lock after',
                    subtitle: _lock.lockAfter.inMinutes >= 1
                        ? '${_lock.lockAfter.inMinutes} minutes in the background'
                        : 'Immediately in the background',
                    icon: Icons.timer_outlined,
                    trailing: OPill(
                      label: '${_lock.lockAfter.inMinutes} min',
                    ),
                    showChevron: false,
                    onTap: enabled ? _pickTimeout : null,
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
