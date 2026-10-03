import 'package:flutter/material.dart';
import '../core/firebase_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'profile_avatar.dart';
import 'account_deletion_panel.dart';

/// Existing Firebase Google and email/password flows. Provider enablement is
/// managed by the project's Firebase configuration.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signUp = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final fb = FirebaseService.I;
    final error = _signUp
        ? await fb.signUpWithEmail(_email.text, _password.text)
        : await fb.signInWithEmail(_email.text, _password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).pop();
  }

  Future<void> _reset() async {
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email to reset your password.');
      return;
    }
    final error = await FirebaseService.I.sendPasswordReset(_email.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Password reset email sent.')),
    );
  }

  Future<void> _google() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await FirebaseService.I.signInWithGoogle();
    if (!mounted) return;
    if (error == 'cancelled') {
      // The user closed the picker — not an error worth shouting about.
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).pop();
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
                  fb.displayName ?? fb.email ?? 'Signed in',
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
            _detailRow(
              'Email status',
              fb.emailVerified ? 'Verified' : 'Unverified',
            ),
          ],
        ),
        const SizedBox(height: 28),

        AccountDeletionPanel(
          service: fb.accountService,
          usesPassword: fb.usesPassword,
          reauthenticate: (password) => fb.reauthenticate(password: password),
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
        Text(
          'Sign in to Ovid Cloud with Google or your email and password. Your email and profile image come from your account.',
          style: TextStyle(fontSize: 13, height: 1.5, color: Aether.textMuted),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: 'Password',
            hintText: _signUp ? 'At least 6 characters' : 'Your password',
          ),
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12.5, color: Aether.danger),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_signUp ? 'Create account' : 'Sign in'),
        ),
        const SizedBox(height: 10),
        // Google sign-in (B7): native account picker → Firebase credential.
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Aether.text,
            side: BorderSide(color: Aether.hairlineStrong),
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _busy ? null : _google,
          icon: const Icon(Icons.g_mobiledata, size: 24),
          label: const Text('Continue with Google'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => setState(() {
                _signUp = !_signUp;
                _error = null;
              }),
              child: Text(
                _signUp
                    ? 'Have an account? Sign in'
                    : 'New here? Create account',
              ),
            ),
            if (!_signUp)
              TextButton(
                onPressed: _reset,
                child: const Text('Forgot password'),
              ),
          ],
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
