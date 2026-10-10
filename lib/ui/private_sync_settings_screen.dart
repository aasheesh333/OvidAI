import 'package:flutter/material.dart';

import '../core/private_sync/production.dart';
import '../core/state.dart';
import '../core/firebase_service.dart';
import '../core/auth_identity.dart';
import 'auth_methods.dart';
import 'private_activity_screen.dart';
import 'private_conversation_screen.dart';

export '../core/private_sync/production.dart'
    show PrivateSyncSettingsController;

class PrivateSyncSettingsScreen extends StatefulWidget {
  const PrivateSyncSettingsScreen({
    super.key,
    this.controller,
    this.reauthenticate,
  });
  final PrivateSyncSettingsController? controller;
  final Future<bool> Function()? reauthenticate;
  @override
  State<PrivateSyncSettingsScreen> createState() =>
      _PrivateSyncSettingsScreenState();
}

class _PrivateSyncSettingsScreenState extends State<PrivateSyncSettingsScreen> {
  bool _busy = false;
  String? _error;
  PrivateSyncSettingsController? get _controller =>
      widget.controller ?? AppState.I.privateSync;
  PrivateSyncProduction? get _owner => _controller is PrivateSyncProduction
      ? _controller as PrivateSyncProduction
      : null;

  Future<bool> _reauthenticate() async {
    if (widget.reauthenticate != null) return widget.reauthenticate!();
    final fb = FirebaseService.I;
    final uid = fb.uid;
    var busy = false;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: const Text('Verify this account to revoke device'),
            content: SingleChildScrollView(
              child: AuthMethods(
                providers: fb.authProviders,
                intent: AuthIntent.reauthenticate,
                linkedIds: fb.linkedProviderIds,
                phoneNumber: fb.phoneNumber,
                social: (id) =>
                    fb.authenticateSocial(id, AuthIntent.reauthenticate),
                phone: () => fb.createPhoneFlow(AuthIntent.reauthenticate),
                onBusyChanged: (value) => update(() => busy = value),
                onSuccess: () => Navigator.of(dialog).pop(true),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(dialog).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    return verified == true && uid != null && fb.uid == uid;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Private sync could not complete. Check your connection and account, then retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    return owner == null
        ? _body(context)
        : AnimatedBuilder(animation: owner, builder: (_, _) => _body(context));
  }

  Widget _body(BuildContext context) {
    final owner = _owner;
    final configured = owner?.configured ?? widget.controller != null;
    final available = owner?.available ?? widget.controller != null;
    final enrolled = owner?.enrolled ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Private sync')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            enrolled ? 'Private sync enabled' : 'Private sync is off',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          const Text(
            'Enabling private sync uploads full conversation transcripts, including tool text and any secret-like text or credentials pasted into a conversation, to your account’s private storage. '
            'Stored provider API keys, sign-in credentials, cookies, permission grants, and attachment files stay local. '
            'Data is transported over HTTPS; this is not end-to-end encryption. Restored conversations and activity are read-only and never run tools or agents.',
          ),
          const SizedBox(height: 16),
          if (!configured)
            const Text(
              'Not configured in this build. A private-sync HTTPS endpoint is required.',
            )
          else if (!available)
            const Text('Sign in and wait for your account to be ready.'),
          if (owner?.error != null)
            Text(
              owner!.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (enrolled) ...[
            Text(
              owner?.deliveryStatus?.retrying == true
                  ? 'Retrying while foregrounded'
                  : 'Sync runs while this app is foregrounded',
            ),
            if (owner?.deliveryStatus?.isStale == true)
              const Text('Restored data may be out of date.'),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(owner!.refresh),
              child: const Text('Refresh now'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(owner!.disable),
              child: const Text('Disable sync on this device'),
            ),
          ] else ...[
            const SizedBox(height: 12),
            const Text(
              'By selecting Enable private sync, you consent to the upload described above.',
            ),
            FilledButton.icon(
              onPressed: !available || _busy
                  ? null
                  : () => _run(_controller!.enroll),
              icon: const Icon(Icons.sync_lock_outlined),
              label: const Text('Enable private sync'),
            ),
          ],
          if (owner?.deviceId != null)
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () =>
                          owner!.revokeDevice(reauthenticate: _reauthenticate),
                    ),
              child: const Text('Verify identity and revoke device'),
            ),
          const Text(
            'Disabling sync works offline and preserves local data. Revoking a device requires fresh sign-in verification. On re-enrollment, old pending uploads are quarantined; portable copies get new IDs while accepted originals stay unchanged.',
          ),
          if (_busy) const LinearProgressIndicator(),
          const Divider(height: 32),
          ListTile(
            title: const Text('Restored conversations'),
            subtitle: const Text('Read-only transcript archive'),
            trailing: const Icon(Icons.chevron_right),
            onTap: owner == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PrivateConversationScreen(owner: owner),
                    ),
                  ),
          ),
          ListTile(
            title: const Text('Private activity'),
            subtitle: const Text('Read-only activity and usage'),
            trailing: const Icon(Icons.chevron_right),
            onTap: owner == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PrivateActivityScreen(owner: owner),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
