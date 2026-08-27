import 'package:flutter/material.dart';
import '../core/firebase_service.dart';
import '../core/theme.dart';

/// Optional Firebase sign-in — email/password. Google sign-in is enabled in
/// the console; its native flow can be layered on later without blocking BYOK.
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

  Widget _signedIn(FirebaseService fb) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 24),
        const CircleAvatar(
          radius: 34,
          backgroundColor: Aether.surfaceRaised,
          child: Icon(Icons.person, size: 36, color: Aether.textMuted),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            fb.displayName ?? fb.email ?? 'Signed in',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        if (fb.email != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                fb.email!,
                style: const TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Sync & backup enabled for this account.',
            style: TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
        ),
        const SizedBox(height: 32),
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

  Widget _signedOut() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 16),
        const Text(
          'Sign in to sync your workspace across devices. Optional — Ovid AI works fully offline with your own API keys.',
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
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
