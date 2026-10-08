import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import '../core/theme.dart';
import '../core/auth_identity.dart';
import 'auth_methods.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/ovid_mark.dart';

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

class _LoginGateState extends State<LoginGate> with WidgetsBindingObserver {
  late final _firebase = widget.service ?? FirebaseService.I;
  bool _bindStarted = false;
  Object? _bindOwner;

  /// True while Firebase.initializeApp is in flight. The splash screen is
  /// shown until this drops to false — no child frame leaks through.
  bool _initializing = true;
  bool _initializationRetrying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _firebase.addListener(_onAuth);
    _kickFirebaseInit();
  }

  Future<void> _kickFirebaseInit() async {
    if (_initializationRetrying) return;
    if (!_initializing) {
      setState(() => _initializationRetrying = true);
    }
    try {
      await _firebase.initialize();
    } catch (_) {
      // Missing configuration is shown below; no anonymous bypass.
    }
    if (!mounted) return;
    setState(() {
      _initializing = false;
      _initializationRetrying = false;
    });
    _onAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _firebase.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (!mounted) return;
    final fb = _firebase;
    final owner = OvidCloudService.I.accountIdentity;
    if (_bindOwner != owner) {
      _bindOwner = owner;
      _bindStarted = false;
    }
    if (!fb.accountReady) _bindStarted = false;
    if (fb.isAvailable && fb.accountReady && !_bindStarted) {
      _bindStarted = true;
      // Bind the Ovid Cloud key in the background; a failure leaves the app
      // usable with the user's own custom providers.
      unawaited(
        widget.bindCloud?.call() ?? OvidCloudService.I.ensureConnected(),
      );
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _firebase.isAvailable &&
        _firebase.accountReady &&
        widget.bindCloud == null) {
      unawaited(OvidCloudService.I.ensureConnected());
    }
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
          return _UnavailableScreen(
            onRetry: _kickFirebaseInit,
            retrying: _initializationRetrying,
          );
        }
        // ── State 3: authenticated ──
        if (fb.isSignedIn) {
          if (!fb.accountReady) {
            return _AccountNotReadyScreen(service: fb);
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

class _SplashScreen extends StatefulWidget {
  const _SplashScreen();

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    _fade = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.55, 0.85, curve: Curves.easeOut),
    );
    _anim.repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      backgroundColor: Aether.bg,
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Brand loop: logo + name reveal (ring draws, agent square pops,
              // then the wordmark fades in) — 3 s, like the brand guidelines.
              OvidMarkAnimated(
                size: 104,
                animation: OvidMarkAnimation.reveal,
                variant: Aether.dark
                    ? OvidMarkVariant.reversed
                    : OvidMarkVariant.primary,
              ),
              const SizedBox(height: AetherSpacing.space6),
              FadeTransition(
                opacity: reducedMotion
                    ? const AlwaysStoppedAnimation<double>(1)
                    : _fade,
                child: OvidWordmark(size: 34, onDark: Aether.dark),
              ),
              const SizedBox(height: AetherSpacing.space3),
              FadeTransition(
                opacity: reducedMotion
                    ? const AlwaysStoppedAnimation<double>(1)
                    : _fade,
                child: Text(
                  Aether.tagline.toUpperCase(),
                  style: AetherType.caption.copyWith(letterSpacing: 2.4),
                ),
              ),
              const SizedBox(height: AetherSpacing.space8),
              // Semantic spinner so tests + accessibility tools can locate the
              // loading affordance (the mark is decorative).
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Aether.accent.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// (Splash underline painter removed with the Ovid Si rebrand — the mark
// animation carries the loading affordance now.)

// ---------------------------------------------------------------------------
// Unavailable screen — Firebase not configured in this build.
// ---------------------------------------------------------------------------

class _UnavailableScreen extends StatelessWidget {
  const _UnavailableScreen({required this.onRetry, required this.retrying});
  final VoidCallback onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AetherSpacing.space6),
              child: AetherCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _GateWordmark(),
                    const SizedBox(height: AetherSpacing.space5),
                     Semantics(
                       header: true,
                       liveRegion: true,
                       child: Text(
                         'Sign-in is unavailable in this build.',
                         style: AetherType.title,
                         textAlign: TextAlign.center,
                       ),
                    ),
                    const SizedBox(height: AetherSpacing.space3),
                    Text(
                       'Ovid could not initialize sign-in for this app. Retry '
                       'to check again, or restart after configuration is '
                       'available.',
                      style: AetherType.bodyMuted,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AetherSpacing.space5),
                     AetherPrimaryButton(
                       label: retrying ? 'Retrying…' : 'Retry',
                       loading: retrying,
                       onPressed: retrying ? null : onRetry,
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
// Account-not-ready screen — signed in but server account check pending or
// failed.
// ---------------------------------------------------------------------------

class _AccountNotReadyScreen extends StatelessWidget {
  const _AccountNotReadyScreen({required this.service});
  final FirebaseService service;

  @override
  Widget build(BuildContext context) {
    final error = service.accountError;
    return Scaffold(
      backgroundColor: Aether.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AetherSpacing.space6),
              child: AetherCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _GateWordmark(),
                    const SizedBox(height: AetherSpacing.space5),
                    Semantics(
                      header: true,
                      liveRegion: true,
                      child: Text(
                        'Confirming your account',
                        style: AetherType.h2,
                      ),
                    ),
                    const SizedBox(height: AetherSpacing.space3),
                    Text(
                      error ??
                          'Checking your account with the Ovid service. '
                              'This usually takes a moment.',
                      style: AetherType.bodyMuted,
                    ),
                    const SizedBox(height: AetherSpacing.space5),
                    if (error == null)
                      Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            semanticsLabel: 'Confirming your account',
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Aether.accent,
                            ),
                          ),
                        ),
                      )
                    else ...[
                      AetherPrimaryButton(
                        label: 'Retry',
                        onPressed: service.retryAccountLogin,
                      ),
                      const SizedBox(height: AetherSpacing.space2),
                      AetherGhostButton(
                        label: 'Sign out',
                        onPressed: service.signOut,
                      ),
                    ],
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
  OverlayEntry? _welcomeEntry;
  Timer? _autoDismiss;

  void _removeWelcome() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
    final entry = _welcomeEntry;
    _welcomeEntry = null;
    entry?.remove();
    entry?.dispose();
  }

  @override
  void dispose() {
    _removeWelcome();
    super.dispose();
  }

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
    if (!mounted || _welcomeEntry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = _welcomeEntry = OverlayEntry(
      builder: (_) => _WelcomeBanner(
        onDismiss: _removeWelcome,
        onInteraction: _cancelWelcomeAutoDismiss,
      ),
    );
    overlay.insert(entry);
    if (!MediaQuery.accessibleNavigationOf(context)) {
      _autoDismiss = Timer(const Duration(seconds: 5), _removeWelcome);
    }
  }

  void _cancelWelcomeAutoDismiss() {
    _autoDismiss?.cancel();
    _autoDismiss = null;
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
  const _WelcomeBanner({
    required this.onDismiss,
    required this.onInteraction,
  });
  final VoidCallback onDismiss;
  final VoidCallback onInteraction;

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
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          minimum: const EdgeInsets.all(AetherSpacing.space4),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
               child: reducedMotion
                   ? _WelcomeContent(
                       onDismiss: widget.onDismiss,
                       onInteraction: widget.onInteraction,
                     )
                   : SlideTransition(
                 position: _slide,
                 child: FadeTransition(
                   opacity: _fade,
                    child: _WelcomeContent(
                      onDismiss: widget.onDismiss,
                      onInteraction: widget.onInteraction,
                    ),
                 ),
               ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeContent extends StatelessWidget {
  const _WelcomeContent({
    required this.onDismiss,
    required this.onInteraction,
  });
  final VoidCallback onDismiss;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => onInteraction(),
    child: SingleChildScrollView(
      child: Semantics(
        liveRegion: true,
        child: AetherCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                liveRegion: true,
                child: Text('Welcome to Ovid Si', style: AetherType.h2),
              ),
              const SizedBox(height: AetherSpacing.space2),
              Text(
                'Explore your available models, create agents, and browse the web.',
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: AetherSpacing.space4),
              AetherPrimaryButton(
                label: "Let's go",
                onPressed: () {
                  onInteraction();
                  onDismiss();
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Login screen — shown when Firebase is available but user is not signed in.
// ---------------------------------------------------------------------------

class _GateWordmark extends StatelessWidget {
  const _GateWordmark();

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: Aether.brandName,
    child: Center(
      child: OvidLockup(markSize: 42, textSize: 28, onDark: Aether.dark),
    ),
  );
}

class _LoginScreen extends StatelessWidget {
  const _LoginScreen({required this.service});
  final FirebaseService service;

  @override
  Widget build(BuildContext context) {
    final deletion = service.lastDeletionReceipt;
    final pending = deletion?.isPending == true;
    final deadline = deletion?.deleteAfter
        ?.toUtc()
        .toIso8601String()
        .replaceFirst('T', '\n')
        .replaceFirst('Z', ' UTC');
    return Scaffold(
      backgroundColor: Aether.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              shrinkWrap: true,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.space4,
                AetherSpacing.space7,
                AetherSpacing.space4,
                AetherSpacing.space6,
              ),
              children: [
                // Brand lockup + tagline.
                const _GateWordmark(),
                const SizedBox(height: AetherSpacing.space3),
                Center(
                  child: Text(
                    Aether.tagline,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: Aether.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: AetherSpacing.space7),
                if (pending) ...[
                  AetherCard(
                    color: Aether.warn.withValues(alpha: 0.10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Account deletion pending',
                          style: AetherType.title,
                        ),
                        const SizedBox(height: AetherSpacing.space2),
                        Text(
                          'Deletion was requested on the server.',
                          style: AetherType.bodyMuted,
                        ),
                        if (deadline != null) ...[
                          const SizedBox(height: AetherSpacing.space2),
                          Text(
                            'Scheduled after\n$deadline',
                            style: AetherType.body,
                          ),
                          const SizedBox(height: AetherSpacing.space2),
                          Text(
                            'Sign in before then to cancel.',
                            style: AetherType.bodyMuted,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.space5),
                ],
                AetherCard(
                  padding: const EdgeInsets.all(AetherSpacing.space4),
                  title: Semantics(
                    header: true,
                    liveRegion: true,
                    child: Text('Sign in or create an account'),
                  ),
                  child: AuthMethods(
                    providers: service.authProviders,
                    intent: AuthIntent.signIn,
                    social: (id) =>
                        service.authenticateSocial(id, AuthIntent.signIn),
                    phone: () => service.createPhoneFlow(AuthIntent.signIn),
                  ),
                ),
                const SizedBox(height: AetherSpacing.space6),
                Text(
                  'By continuing you agree to use Ovid responsibly. '
                  'Abuse, automated farming, or sharing accounts may '
                  'lead to suspension.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Aether.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
