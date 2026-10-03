import 'package:flutter/material.dart';
import '../core/firebase_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'profile_avatar.dart';
import 'account_deletion_panel.dart';
import '../core/auth_identity.dart';
import '../core/auth_providers.dart';
import 'auth_methods.dart';

/// Social/phone identity and explicit same-UID linking.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  Future<String?> _verifyIdentity(FirebaseService fb) async {
    if (fb.reauthProviders.isEmpty) return legacyAuthMigrationHelp;
    final expectedUid = fb.uid;
    var busy = false;
    final verified = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: const Text('Verify this account'),
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
    if (verified != true) return 'cancelled';
    if (fb.uid != expectedUid) return 'The account changed. Verify again.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final fb = FirebaseService.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Account')),
      body: AnimatedBuilder(
        animation: fb,
        builder: (_, _) {
          if (fb.isSignedIn) return _signedIn(fb);
          return _signedOut();
        },
      ),
    );
  }

  Future<void> _editName(FirebaseService fb) async {
    final ctrl = TextEditingController(text: fb.displayName ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: Aether.surface,
        title: const Text('Edit name', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Your name'),
          onSubmitted: (v) => Navigator.pop(d, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    final error = await fb.updateDisplayName(name);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Name updated.')));
  }

  Widget _signedIn(FirebaseService fb) {
    final tier = AppState.I.ovidCloudTier;
    final isPaid = AppState.I.ovidCloudIsPaid;
    final photo = fb.photoUrl;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 12),
        // ── Profile header (avatar + name + email + verified) ──
        Center(child: ProfileAvatar(photoUrl: photo, radius: 40)),
        const SizedBox(height: 14),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  fb.displayName ?? fb.email ?? fb.phoneNumber ?? 'Signed in',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _editName(fb),
                icon: Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: Aether.textMuted,
                ),
                tooltip: 'Edit name',
              ),
            ],
          ),
        ),
        if (fb.email != null)
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    fb.email!,
                    style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  fb.emailVerified ? Icons.verified : Icons.error_outline,
                  size: 14,
                  color: fb.emailVerified ? Aether.accent : Aether.warnLight,
                ),
              ],
            ),
          ),
        const SizedBox(height: 24),

        // ── Plan card ──
        _AccountCard(
          icon: Icons.auto_awesome,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Ovid Cloud plan',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Aether.text,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isPaid ? Aether.accent : Aether.surfaceAlt,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    isPaid ? '${tier.toUpperCase()} PLAN' : 'FREE',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: isPaid ? Colors.white : Aether.textMuted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              isPaid
                  ? 'Paid plan active. Check remaining usage in Usage.'
                  : 'Free plan — just chat. Upgrade for more usage.',
              style: TextStyle(
                fontSize: 12,
                color: Aether.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // ── Account details (FAANG-style) ──
        _AccountCard(
          icon: Icons.badge_outlined,
          children: [
            _detailRow('Email', fb.email ?? '—'),
            const SizedBox(height: 10),
            _detailRow('Phone', fb.phoneNumber ?? '—'),
            const SizedBox(height: 10),
            _detailRow(
              'Email status',
              fb.emailVerified ? 'Verified' : 'Unverified',
            ),
          ],
        ),
        const SizedBox(height: 28),

        Text(
          'Linked sign-in methods: ${fb.linkedProviderIds.where((id) => id != 'password').join(', ')}',
        ),
        if (fb.linkedProviderIds.contains('password'))
          const Text(legacyAuthMigrationHelp),
        AuthMethods(
          key: ValueKey('link-${fb.uid}'),
          providers: fb.authProviders,
          intent: AuthIntent.link,
          linkedIds: fb.linkedProviderIds,
          social: (id) async {
            final error = await _verifyIdentity(fb);
            if (error != null) return error;
            return fb.authenticateSocial(id, AuthIntent.link);
          },
          phone: () => fb.createPhoneFlow(AuthIntent.link),
          beforePhone: () => _verifyIdentity(fb),
        ),
        const SizedBox(height: 16),

        AccountDeletionPanel(
          key: ValueKey('delete-${fb.uid}'),
          service: fb.accountService,
          reauthenticate: (_) => _verifyIdentity(fb),
          requestDeletion: fb.requestAccountDeletion,
        ),
        const SizedBox(height: 16),

        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Aether.danger,
            side: const BorderSide(color: Aether.danger),
            padding: const EdgeInsets.symmetric(vertical: 13),
          ),
          onPressed: () => fb.signOut(),
          icon: const Icon(Icons.logout, size: 17),
          label: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 108,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: Aether.textFaint),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12.5,
              fontFamily: Aether.mono,
              color: Aether.text,
            ),
          ),
        ),
      ],
    );
  }

  Widget _signedOut() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        if (FirebaseService.I.lastDeletionReceipt?.isPending == true)
          Text(
            'Deletion requested on the server. Scheduled after ${FirebaseService.I.lastDeletionReceipt!.deleteAfter!.toUtc().toIso8601String()} (UTC). Sign in before then to cancel.',
          ),
        AuthMethods(
          providers: FirebaseService.I.authProviders,
          intent: AuthIntent.signIn,
          social: (id) =>
              FirebaseService.I.authenticateSocial(id, AuthIntent.signIn),
          phone: () => FirebaseService.I.createPhoneFlow(AuthIntent.signIn),
        ),
      ],
    );
  }
}

/// A rounded card container used by the FAANG-style account screen.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.icon, required this.children});
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
