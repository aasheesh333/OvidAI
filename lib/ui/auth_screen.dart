import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/firebase_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'profile_avatar.dart';
import 'account_deletion_panel.dart';
import '../core/auth_identity.dart';
import '../core/auth_providers.dart';
import 'auth_methods.dart';
import 'billing_screen.dart';
import 'widgets/aether_primitives.dart';

/// Social/phone identity and explicit same-UID linking.
///
/// The redesigned account screen orders the signed-in surface hero → plan →
/// details → linked methods → danger zone: the hero carries the avatar, name
/// and plan pill; the plan card links through to Plans & Billing; details are
/// copy rows; the danger zone holds deletion and sign-out. All existing
/// behavior — AnimatedBuilder on FirebaseService, _verifyIdentity with its
/// busy PopScope, the edit-name dialog, phone/social/link flows via
/// AuthMethods, AccountDeletionPanel wiring, and the sign-out button — is
/// preserved.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.service});

  /// Test seam: inject a FirebaseService (defaults to the singleton).
  final FirebaseService? service;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final FirebaseService _firebase = widget.service ?? FirebaseService.I;

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
    final fb = _firebase;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Account')),
      body: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: AnimatedBuilder(
              animation: Listenable.merge([fb, AppState.I]),
              builder: (_, _) {
                if (fb.isSignedIn) return _signedIn(fb);
                return _signedOut(fb);
              },
            ),
          ),
        ),
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
    // Defer disposal until after the dialog's reverse transition completes.
    // The TextField in the dialog is rebuilt during pop animation and
    // disposing synchronously causes "used after being disposed" assertions.
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (name == null || name.isEmpty) return;
    final error = await fb.updateDisplayName(name);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error ?? 'Name updated.')));
  }

  // ───────────────────────────────────────────────────────── signed-in ──

  Widget _signedIn(FirebaseService fb) {
    final tier = AppState.I.ovidCloudTier;
    final isPaid = AppState.I.ovidCloudIsPaid;
    final linked = fb.linkedProviderIds;
    final nonPassword = linked.where((id) => id != 'password').toList()..sort();
    final hasPassword = linked.contains('password');

    // One column child: the account page is short, and a single sliver child
    // keeps the hero (avatar, name, plan pill) composed instead of letting the
    // lazy list recycle it once the user scrolls down to the cards below.
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ProfileHeader(
              photoUrl: fb.photoUrl,
              displayName: fb.displayName,
              fallback: fb.email ?? fb.phoneNumber ?? 'Signed in',
              planPill: AetherPill(
                label: _planPill(tier, isPaid),
                color: isPaid ? Aether.accentC : Aether.textMuted,
                filled: isPaid,
              ),
              onEdit: () => _editName(fb),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.space5,
                AetherSpacing.space5,
                AetherSpacing.space5,
                AetherSpacing.space6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Plan card — links through to Plans & Billing (Money) ──
                  AetherCard(
                    title: _cardTitle(Icons.auto_awesome, 'Ovid Cloud plan'),
                    footer: Align(
                      alignment: Alignment.centerLeft,
                      child: AetherGhostButton(
                        label: 'Manage plan',
                        icon: Icons.arrow_forward,
                        onPressed: () => _openBilling(),
                      ),
                    ),
                    child: Text(
                      isPaid
                          ? 'Paid plan active. Check remaining usage in Usage.'
                          : 'Free plan — just chat. Upgrade for more usage.',
                      style: AetherType.body,
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.space4),

                  // ── Account details ──
                  AetherCard(
                    title: _cardTitle(Icons.badge_outlined, 'Account details'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _DetailRow(
                          label: 'Email',
                          value: fb.email ?? '—',
                          canCopy: fb.email != null,
                        ),
                        const SizedBox(height: AetherSpacing.space3),
                        _DetailRow(
                          label: 'Phone',
                          value: fb.phoneNumber ?? '—',
                          canCopy: fb.phoneNumber != null,
                        ),
                        const SizedBox(height: AetherSpacing.space3),
                        _DetailRow(
                          label: 'Email status',
                          value: fb.email == null
                              ? 'No email linked'
                              : fb.emailVerified
                              ? 'Verified'
                              : 'Unverified',
                          canCopy: false,
                        ),
                        const SizedBox(height: AetherSpacing.space3),
                        _DetailRow(
                          label: 'User ID',
                          value: fb.uid ?? '—',
                          canCopy: fb.uid != null,
                          mono: true,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.space4),

                  // ── Linked sign-in methods ──
                  AetherCard(
                    title: _cardTitle(Icons.link, 'Linked sign-in methods'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (nonPassword.isEmpty)
                          Text(
                            'No social or phone providers linked yet.',
                            style: AetherType.bodyMuted,
                          )
                        else
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final id in nonPassword)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        _providerIcon(id),
                                        size: 24,
                                        color: Aether.accentC,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              AuthProviders.labelFor(id),
                                              style: AetherType.body,
                                            ),
                                            Text(
                                              fb.authProviders.isEnabled(id)
                                                  ? 'Linked'
                                                  : 'Linked · Unavailable in this build',
                                              style: AetherType.label,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        const SizedBox(height: AetherSpacing.space4),
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
                      ],
                    ),
                  ),
                  if (hasPassword) ...[
                    const SizedBox(height: AetherSpacing.space4),
                    _LegacyPasswordWarnCard(),
                  ],
                  const SizedBox(height: AetherSpacing.space6),

                  // ── Danger zone ──
                  _DangerZoneCard(
                    deletion: AccountDeletionPanel(
                      key: ValueKey('delete-${fb.uid}'),
                      service: fb.accountService,
                      reauthenticate: (_) => _verifyIdentity(fb),
                      requestDeletion: fb.requestAccountDeletion,
                    ),
                    signOut: AetherDangerButton(
                      label: 'Sign out',
                      icon: Icons.logout,
                      onPressed: () => fb.signOut(),
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.space6),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _openBilling() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/billing'),
        builder: (_) => const BillingScreen(),
      ),
    );
  }

  /// Card headings wrap so every section remains identifiable at large text.
  Widget _cardTitle(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Aether.textMuted),
        const SizedBox(width: 8),
        Flexible(
          child: Text(label),
        ),
      ],
    );
  }

  String _planPill(String tier, bool isPaid) {
    if (!isPaid) return 'FREE';
    return switch (tier) {
      '3x' => 'PLUS',
      '7x' => 'PRO',
      '15x' => 'MAX',
      _ => tier.toUpperCase(),
    };
  }

  IconData _providerIcon(String id) {
    return switch (id) {
      'google.com' => Icons.g_mobiledata,
      'phone' => Icons.phone_iphone,
      'github.com' => Icons.code,
      'apple.com' => Icons.apple,
      'microsoft.com' => Icons.window,
      'facebook.com' => Icons.facebook,
      _ => Icons.verified_user_outlined,
    };
  }

  // ──────────────────────────────────────────────────────── signed-out ──

  Widget _signedOut(FirebaseService fb) {
    final receipt = fb.lastDeletionReceipt;
    final pending = receipt?.isPending == true;
    return ListView(
      padding: const EdgeInsets.all(AetherSpacing.space5),
      children: [
        if (pending)
          Padding(
            padding: const EdgeInsets.only(bottom: AetherSpacing.space4),
            child: DeletionPendingBanner(receipt: receipt!),
          ),
        AetherCard(
          title: _cardTitle(Icons.login, 'Sign in to Ovid'),
          child: AuthMethods(
            providers: fb.authProviders,
            intent: AuthIntent.signIn,
            social: (id) => fb.authenticateSocial(id, AuthIntent.signIn),
            phone: () => fb.createPhoneFlow(AuthIntent.signIn),
          ),
        ),
      ],
    );
  }
}

/// Account hero: gradient background + centered avatar + name + plan pill.
/// Contact details live once in the Account details card below, so the hero
/// stays a calm identity summary.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.photoUrl,
    required this.displayName,
    required this.fallback,
    required this.planPill,
    required this.onEdit,
  });
  final String? photoUrl;
  final String? displayName;
  final String fallback;
  final Widget planPill;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final name = displayName?.trim().isNotEmpty == true
        ? displayName!
        : fallback;
    // Content owns the height; the gradient fills it rather than constraining
    // long identities to a fixed number of scaled lines.
    return Stack(
      children: [
        const Positioned.fill(
          child: AetherGradientHeader(child: SizedBox.shrink()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.space5,
            AetherSpacing.space4,
            AetherSpacing.space5,
            AetherSpacing.space4,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: ProfileAvatar(
                  photoUrl: photoUrl,
                  displayName: displayName,
                  radius: 40,
                ),
              ),
              const SizedBox(height: AetherSpacing.space4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      style: AetherType.h1,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AetherGhostButton(
                    label: 'Edit name',
                    icon: Icons.edit_outlined,
                    iconOnly: true,
                    iconSize: 48,
                    tooltip: 'Edit name',
                    onPressed: onEdit,
                  ),
                ],
              ),
              const SizedBox(height: AetherSpacing.space3),
              Center(child: planPill),
            ],
          ),
        ),
      ],
    );
  }
}

/// Label/value row with an optional copy button.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.canCopy,
    this.mono = false,
  });
  final String label;
  final String value;
  final bool canCopy;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: AetherType.label),
        const SizedBox(height: AetherSpacing.space1),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                value,
                style: mono
                    ? AetherType.body.copyWith(fontFamily: Aether.mono)
                    : AetherType.body,
              ),
            ),
            if (canCopy)
              AetherGhostButton(
                label: 'Copy $label',
                icon: Icons.copy_rounded,
                iconOnly: true,
                iconSize: 48,
                tooltip: 'Copy $label',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!context.mounted) return;
                  // Copy feedback describes the latest clipboard contents;
                  // replace the previous message instead of queuing stale ones.
                  ScaffoldMessenger.of(context)
                    ..removeCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text('$label copied')));
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Warning card shown when `providerData` still contains legacy `password`.
class _LegacyPasswordWarnCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AetherCard(
      color: Aether.surface,
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: Aether.warnLight),
          const SizedBox(width: 8),
          const Flexible(
            child: Text('Legacy password sign-in'),
          ),
        ],
      ),
      child: Text(legacyAuthMigrationHelp, style: AetherType.body),
    );
  }
}

/// Danger zone card: red left rule, deletion panel, then Sign out at bottom.
class _DangerZoneCard extends StatelessWidget {
  const _DangerZoneCard({required this.deletion, required this.signOut});
  final Widget deletion;
  final Widget signOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        border: Border.all(color: Aether.hairline),
        boxShadow: AetherShadows.shadowS,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        child: Container(
          // Full-height danger left rule. A decoration border is used rather
          // than a stretched Row child so the rule adapts to content height
          // without needing a bounded cross-axis (ListView is unbounded).
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: Aether.danger, width: 3),
            ),
          ),
          padding: const EdgeInsets.all(AetherSpacing.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: Aether.danger),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Danger zone',
                      style: AetherType.title.copyWith(color: Aether.dangerC),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AetherSpacing.space3),
              Divider(height: 1, thickness: 1, color: Aether.hairline),
              const SizedBox(height: AetherSpacing.space3),
              deletion,
              const SizedBox(height: AetherSpacing.space4),
              Divider(height: 1, thickness: 1, color: Aether.hairline),
              const SizedBox(height: AetherSpacing.space3),
              Text('Session', style: AetherType.title),
              const SizedBox(height: AetherSpacing.space2),
              Text(
                'Sign out of this device without deleting your account.',
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: AetherSpacing.space3),
              signOut,
            ],
          ),
        ),
      ),
    );
  }
}
