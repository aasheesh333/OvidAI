import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import '../core/theme.dart';
import '../core/auth_identity.dart';
import 'auth_methods.dart';

/// Mandatory Firebase sign-in gate with server account acknowledgement.
///
/// Three states:
///  1. **loading** — Firebase is initializing; show a splash screen.
///  2. **unauthenticated** — Firebase ready, no user; show the login screen.
///  3. **authenticated** — signed in; show the child (app).
///
/// Ovid Cloud assigns a per-user key after authenticated account checks, so
/// the app requires login before use. On the first signed-in frame the gate
/// binds the user's Ovid Cloud key in the background (mint → secure storage →
/// Auto mode).
///
/// Missing Firebase configuration fails closed. Tests explicitly use
/// [disabledForTest] when exercising unrelated app features.
class LoginGate extends StatefulWidget {
  const LoginGate({
    super.key,
    required this.child,
    this.service,
    this.bindCloud,
  });
  final Widget child;
  final FirebaseService? service;
  final Future<void> Function()? bindCloud;

  /// Test seam: skip the gate entirely (host widget tests pump the shell).
  @visibleForTesting
  static bool disabledForTest = false;

  @override
  State<LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<LoginGate> {
  late final _firebase = widget.service ?? FirebaseService.I;
  bool _bindStarted = false;

  /// True while Firebase.initializeApp is in flight. The splash screen is
  /// shown until this drops to false — no child frame leaks through.
  bool _initializing = true;

  @override
  void initState() {
    super.initState();
    _firebase.addListener(_onAuth);
    _kickFirebaseInit();
  }

  Future<void> _kickFirebaseInit() async {
    try {
      await _firebase.initialize();
    } catch (_) {
      // Missing configuration is shown below; no anonymous bypass.
    }
    if (!mounted) return;
    setState(() => _initializing = false);
    _onAuth();
  }

  @override
  void dispose() {
    _firebase.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (!mounted) return;
    final fb = _firebase;
    if (!fb.accountReady) _bindStarted = false;
    if (fb.isAvailable && fb.accountReady && !_bindStarted) {
      _bindStarted = true;
      // Bind the Ovid Cloud key in the background; a failure leaves the app
      // usable with the user's own custom providers.
      unawaited(widget.bindCloud?.call() ?? OvidCloudService.I.bindOvidCloud());
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (LoginGate.disabledForTest) return widget.child;

    // ── State 1: loading (Firebase initializing) ──
    if (_initializing) return const _SplashScreen();

    return AnimatedBuilder(
      animation: _firebase,
      builder: (_, _) {
        final fb = _firebase;
        // Firebase not configured in this build → no anonymous bypass.
        if (!fb.isAvailable) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Sign-in is unavailable in this build.'),
                  TextButton(
                    onPressed: _kickFirebaseInit,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        // ── State 3: authenticated ──
        if (fb.isSignedIn) {
          if (!fb.accountReady) {
            return Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        fb.accountError ?? 'Confirming account status…',
                        textAlign: TextAlign.center,
                      ),
                      if (fb.accountError != null) ...[
                        TextButton(
                          onPressed: fb.retryAccountLogin,
                          child: const Text('Retry account check'),
                        ),
                        TextButton(
                          onPressed: fb.signOut,
                          child: const Text('Sign out and sign in again'),
                        ),
                      ] else
                        const CircularProgressIndicator(),
                    ],
                  ),
                ),
              ),
            );
          }
          return _PostLoginWelcomeGate(child: widget.child);
        }
        // ── State 2: unauthenticated ──
        return _LoginScreen(service: fb);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Splash screen — shown while Firebase initializes.
// ---------------------------------------------------------------------------

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 56, color: Aether.accent),
            const SizedBox(height: 24),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Aether.accent.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Post-login welcome overlay — shown once per install after first sign-in.
// ---------------------------------------------------------------------------

/// SharedPreferences key. Present ⇒ the welcome has been shown.
const _kWelcomedPref = 'ovid_welcomed';

class _PostLoginWelcomeGate extends StatefulWidget {
  const _PostLoginWelcomeGate({required this.child});
  final Widget child;

  @override
  State<_PostLoginWelcomeGate> createState() => _PostLoginWelcomeGateState();
}

class _PostLoginWelcomeGateState extends State<_PostLoginWelcomeGate> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _maybeShowWelcome();
  }

  Future<void> _maybeShowWelcome() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kWelcomedPref) == true) {
      // Already welcomed — nothing to do.
      if (mounted) setState(() => _checked = true);
      return;
    }
    // Mark as welcomed immediately so it never fires twice.
    await prefs.setBool(_kWelcomedPref, true);
    if (!mounted) return;
    setState(() => _checked = true);
    // Show the non-modal overlay after the first frame of the app is painted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showWelcomeOverlay();
    });
  }

  void _showWelcomeOverlay() {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    Timer? autoDismiss;

    void remove() {
      autoDismiss?.cancel();
      entry.remove();
    }

    entry = OverlayEntry(builder: (_) => _WelcomeBanner(onDismiss: remove));
    overlay.insert(entry);
    autoDismiss = Timer(const Duration(seconds: 5), remove);
  }

  @override
  Widget build(BuildContext context) {
    // While checking prefs (microtask-fast), still render the child — the
    // welcome overlay appears ON TOP of the app, it never blocks it.
    if (!_checked) return widget.child;
    return widget.child;
  }
}

class _WelcomeBanner extends StatefulWidget {
  const _WelcomeBanner({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  State<_WelcomeBanner> createState() => _WelcomeBannerState();
}

class _WelcomeBannerState extends State<_WelcomeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeIn);
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16 + bottom,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: GestureDetector(
            onTap: widget.onDismiss,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              color: Aether.surface,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome to Ovid',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Aether.text,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Your AI assistant is ready. Chat with any model, '
                      'create agents, browse the web.',
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: Aether.textMuted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Aether.accent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: widget.onDismiss,
                        child: const Text("Let's go"),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Login screen — shown when Firebase is available but user is not signed in.
// ---------------------------------------------------------------------------

class _LoginScreen extends StatelessWidget {
  const _LoginScreen({required this.service});
  final FirebaseService service;

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
                if (service.lastDeletionReceipt?.isPending == true)
                  Text(
                    'Deletion requested on the server. Scheduled after ${service.lastDeletionReceipt!.deleteAfter!.toUtc().toIso8601String()} (UTC). Sign in before then to cancel.',
                    textAlign: TextAlign.center,
                  ),
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
                  'Sign in to start. Your account unlocks the '
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
                AuthMethods(
                  providers: service.authProviders,
                  intent: AuthIntent.signIn,
                  social: (id) =>
                      service.authenticateSocial(id, AuthIntent.signIn),
                  phone: () => service.createPhoneFlow(AuthIntent.signIn),
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
