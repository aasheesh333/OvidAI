import 'dart:async';

import 'package:flutter/material.dart';

import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import '../core/theme.dart';

/// Mandatory Google sign-in gate (2026-10-01).
///
/// Ovid Cloud assigns a per-user key only after a verified Google sign-in, so
/// the app requires login before use. On the first signed-in frame the gate
/// binds the user's Ovid Cloud key in the background (mint → secure storage →
/// Auto mode).
///
/// Safety: when Firebase is NOT configured in this build (e.g. tests, or a
/// local dev build with no `google-services.json`), the gate lets the app
/// through unchanged — it never bricks a build that cannot sign in.
class LoginGate extends StatefulWidget {
  const LoginGate({super.key, required this.child});
  final Widget child;

  /// Test seam: skip the gate entirely (host widget tests pump the shell).
  @visibleForTesting
  static bool disabledForTest = false;

  @override
  State<LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<LoginGate> {
  bool _bindStarted = false;

  @override
  void initState() {
    super.initState();
    FirebaseService.I.addListener(_onAuth);
    _onAuth();
  }

  @override
  void dispose() {
    FirebaseService.I.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (!mounted) return;
    final fb = FirebaseService.I;
    if (fb.isAvailable && fb.isSignedIn && !_bindStarted) {
      _bindStarted = true;
      // Bind the Ovid Cloud key in the background; a failure leaves the app
      // usable with the user's own custom providers.
      unawaited(OvidCloudService.I.bindOvidCloud());
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (LoginGate.disabledForTest) return widget.child;
    return AnimatedBuilder(
      animation: FirebaseService.I,
      builder: (_, _) {
        final fb = FirebaseService.I;
        // Firebase not configured in this build → do not block usage.
        if (!fb.isAvailable) return widget.child;
        if (fb.isSignedIn) return widget.child;
        return const _LoginScreen();
      },
    );
  }
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen();

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _google() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await FirebaseService.I.signInWithGoogle();
    if (!mounted) return;
    if (error == 'cancelled') {
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
    // On success the FirebaseService auth listener flips the gate to the app.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(28),
              children: [
                const SizedBox(height: 8),
                Icon(Icons.auto_awesome, size: 48, color: Aether.accent),
                const SizedBox(height: 20),
                Text(
                  'Welcome to Ovid',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: Aether.text,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Sign in with Google to start. Your account unlocks the '
                  'built-in Ovid models and keeps your usage synced across '
                  'devices.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.5,
                    color: Aether.textMuted,
                  ),
                ),
                const SizedBox(height: 28),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _busy ? null : _google,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.g_mobiledata, size: 26),
                  label: Text(_busy ? 'Signing in…' : 'Continue with Google'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: Aether.danger,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  'By continuing you agree to use Ovid responsibly. Abuse, '
                  'automated farming, or sharing accounts may lead to '
                  'suspension.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Aether.textFaint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
