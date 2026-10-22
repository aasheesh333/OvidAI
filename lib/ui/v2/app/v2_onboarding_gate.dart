import 'package:flutter/material.dart';

import '../../../core/auth_identity.dart';
import '../../../core/auth_phone_flow.dart';
import '../../../core/auth_providers.dart';
import '../../../core/diag.dart';
import '../../../core/firebase_service.dart';
import '../../../core/play_billing.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/state.dart';
import '../../auth_methods.dart' show AuthPhoneDialog;
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../onboarding/language_goal_page.dart';
import '../onboarding/onboarding_prefs.dart';
import '../onboarding/onboarding_welcome.dart';
import '../onboarding/paywall_page.dart';
import '../onboarding/sign_in_page.dart';
import '../onboarding/splash_page.dart';

export '../onboarding/onboarding_prefs.dart'
    show
        V2OnboardingSnapshot,
        V2OnboardingStore,
        kV2OnboardingWelcomeVersion,
        kV2WelcomeSeenPref;

// TODO(l10n): move the gate's status and error copy to the ARB files.

/// The slice of Firebase auth the onboarding gate drives.
///
/// [FirebaseService] is the production implementation (through
/// [_FirebaseOnboardingAuth]); tests provide a plain fake. Keeping the seam
/// this small means the gate never reaches for a singleton directly, while
/// `accountReady`/`isSignedIn` remain the single source of truth.
abstract class V2OnboardingAuth implements Listenable {
  /// Firebase is configured and initialized for this build.
  bool get isAvailable;

  /// A non-anonymous user is signed in.
  bool get isSignedIn;

  /// The signed-in account passed the server admission check.
  bool get accountReady;

  /// Why admission failed, if it did.
  String? get accountError;

  /// Display name / email / phone for the signed-in user.
  String get accountLabel;

  Future<void> initialize();

  Future<void> retryAccountLogin();

  /// Signs the current account out, so a rejected account can be replaced.
  Future<void> signOut();

  /// Returns null on success, `'cancelled'` when the user dismissed the
  /// provider, otherwise a human-readable error.
  Future<String?> authenticateSocial(String providerId, AuthIntent intent);

  PhoneAuthFlow createPhoneFlow(AuthIntent intent);
}

/// Production adapter over [FirebaseService.I].
class _FirebaseOnboardingAuth implements V2OnboardingAuth {
  _FirebaseOnboardingAuth(this._service);

  final FirebaseService _service;

  @override
  bool get isAvailable => _service.isAvailable;

  @override
  bool get isSignedIn => _service.isSignedIn;

  @override
  bool get accountReady => _service.accountReady;

  @override
  String? get accountError => _service.accountError;

  @override
  String get accountLabel => _service.accountLabel;

  @override
  Future<void> initialize() => _service.initialize();

  @override
  Future<void> retryAccountLogin() => _service.retryAccountLogin();

  @override
  Future<void> signOut() => _service.signOut();

  @override
  Future<String?> authenticateSocial(String providerId, AuthIntent intent) =>
      _service.authenticateSocial(providerId, intent);

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) =>
      _service.createPhoneFlow(intent);

  @override
  void addListener(VoidCallback listener) => _service.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _service.removeListener(listener);
}

/// SharedPreferences key for the v2 onboarding welcome marker. It now lives in
/// `onboarding_prefs.dart` (next to the other durable choice keys) and is
/// re-exported above so existing imports of this file keep working. It stays
/// separate from `AppState`'s in-app welcome notice (`ovid_welcome`) so
/// finishing the onboarding tour never suppresses that unrelated notice.

enum _Step { welcome, language, signIn, done }

/// Production onboarding gate for the v2 shell.
///
/// Order: splash (startup pending) → welcome (first run) → language & goal →
/// sign-in → paywall → [child]. A signed-in, admitted user skips straight to
/// [child]. The live [LoginGate] is intentionally left untouched: the app
/// router/flag owner decides which gate wraps the shell.
///
/// Nothing here fakes a result: Google and phone are the only providers, a
/// declined purchase continues without an entitlement, and a failed social or
/// phone attempt is surfaced instead of advancing.
class V2OnboardingGate extends StatefulWidget {
  const V2OnboardingGate({
    super.key,
    required this.child,
    this.auth,
    this.purchase,
    this.purchaseForPeriod,
    this.restorePurchases,
    this.store,
    this.testStore,
    this.welcomeVersion = kV2OnboardingWelcomeVersion,
  });

  /// The app shown once onboarding and account admission are complete.
  final Widget child;

  /// Test seam; production uses [FirebaseService.I].
  final V2OnboardingAuth? auth;

  /// Called when the user starts the trial for [planId]. Returns whether the
  /// billing layer completed a purchase. The default returns false: the gate
  /// continues without granting anything.
  final Future<bool> Function(String planId)? purchase;

  /// Period-aware purchase seam. When set, the paywall buys the exact product
  /// the user selected; [purchase] is only the monthly fallback for callers
  /// that predate the period toggle. Without this a yearly selection can never
  /// reach checkout.
  final Future<bool> Function(String planId, OvidBillingPeriod period)?
  purchaseForPeriod;

  /// The real restore seam for the paywall. Null leaves Restore disabled
  /// instead of pretending it ran.
  final Future<V2PaywallRestoreResult> Function()? restorePurchases;

  /// Durable store for the welcome marker and the first-run choices. The
  /// default reads and writes SharedPreferences.
  final V2OnboardingStore? store;

  /// Whether this build talks to the RevenueCat Test Store. Defaults to the
  /// compile-time [kRevenueCatTestStore]; overridable so tests can prove the
  /// note appears only in a Test Store build.
  final bool? testStore;

  /// Marker value written to [kV2WelcomeSeenPref]. Overridable for tests.
  final String welcomeVersion;

  @override
  State<V2OnboardingGate> createState() => _V2OnboardingGateState();
}

class _V2OnboardingGateState extends State<V2OnboardingGate> {
  late final V2OnboardingAuth _auth =
      widget.auth ?? _FirebaseOnboardingAuth(FirebaseService.I);
  late final Future<bool> Function(String planId) _purchase =
      widget.purchase ?? _declinePurchase;
  late final V2OnboardingStore _store =
      widget.store ?? const V2OnboardingStore();
  late final bool _testStore = widget.testStore ?? kRevenueCatTestStore;

  static Future<bool> _declinePurchase(String planId) async => false;

  bool _booting = true;
  bool _booted = false;
  String? _startupError;

  /// Startup progress reflects the work actually left to do. It is never a
  /// timer: each step moves it once, and it stays put while a step blocks.
  double _startupProgress = 0;
  String _startupLabel = 'Starting your agent';

  _Step _step = _Step.welcome;

  /// Which step opened the language screen, so Back returns there instead of
  /// always restarting the tour.
  _Step _languageReturn = _Step.welcome;

  bool _welcomeBusy = false;
  String? _welcomeError;

  String _languageId = 'en';
  Set<String> _goalIds = {'build'};
  bool _savingChoices = false;
  String? _choicesError;

  bool _signInBusy = false;
  String? _signInError;
  Future<void> Function()? _lastSignInAction;

  bool _paywallSeen = false;
  bool _purchasing = false;
  String? _paywallError;
  String _selectedPlanId = 'plus';
  V2PaywallPeriod _paywallPeriod = V2PaywallPeriod.monthly;

  /// Paywall currency id (`usd` / `inr`). Persisted by [V2OnboardingStore].
  String _currencyId = 'usd';

  bool _accountRetrying = false;
  bool _accountSigningOut = false;
  String? _accountRetryError;

  @override
  void initState() {
    super.initState();
    _auth.addListener(_onAuth);
    // The paywall shows the store's own prices and disables a period Play does
    // not sell. The catalogue loads asynchronously, so rebuild when it lands.
    PlayBillingService.I.addListener(_onBillingChanged);
    _boot();
  }

  void _onBillingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PlayBillingService.I.removeListener(_onBillingChanged);
    _auth.removeListener(_onAuth);
    super.dispose();
  }

  Future<void> _boot() async {
    if (!_booting) {
      setState(() {
        _booting = true;
        _startupError = null;
        _startupProgress = 0;
        _startupLabel = 'Starting your agent';
      });
    }

    Object? failure;
    try {
      await _auth.initialize();
    } catch (error) {
      failure = error;
    }

    if (!mounted) return;
    setState(() {
      _startupProgress = 0.5;
      _startupLabel = 'Restoring your choices';
    });

    V2OnboardingSnapshot? snapshot;
    try {
      snapshot = await _store.load(welcomeVersion: widget.welcomeVersion);
    } catch (_) {
      // Preferences are an enhancement here: without them the tour starts
      // from the top instead of blocking the app.
    }
    if (!mounted) return;

    final language = snapshot?.languageId;
    final goals = snapshot?.goalIds ?? const <String>{};

    setState(() {
      _booting = false;
      _booted = true;
      _startupError = failure == null
          ? null
          : 'Ovid could not start. Check your connection and try again.';
      _languageId = language ?? 'en';
      _goalIds = goals.isEmpty ? {'build'} : goals;
      _currencyId = snapshot?.currencyId ?? 'usd';
      if (_auth.isSignedIn) {
        _step = _Step.done;
      } else if (snapshot == null || !snapshot.welcomeSeen) {
        _step = _Step.welcome;
      } else if (language == null) {
        _step = _Step.language;
      } else {
        _step = _Step.signIn;
      }
    });
    // The tour's language choice is the voice/assistant language, not the
    // app-UI locale (the UI ships English only). Apply it when the person has
    // not already picked a voice language in Settings.
    if (language != null && AppState.I.voiceLanguage.isEmpty) {
      await AppState.I.setVoiceLanguage(language);
    }
  }

  void _onAuth() {
    if (!mounted) return;
    setState(() {
      // Losing the session from inside the app returns to sign-in rather than
      // leaving a signed-out shell on screen.
      if (_booted && !_auth.isSignedIn && _step == _Step.done) {
        _step = _Step.signIn;
        _paywallSeen = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) return _splash();

    final startupError =
        _startupError ??
        (!_auth.isAvailable
            ? 'Sign-in is unavailable in this build. Retry to check again.'
            : null);
    if (startupError != null) return _splash(error: startupError);

    if (_auth.isSignedIn) {
      if (!_auth.accountReady) return _accountPending(context);
      // Signing in during the tour lands on the paywall; an account that was
      // already signed in at launch goes straight to the app.
      if (_step != _Step.done) {
        return _paywallSeen ? widget.child : _paywall();
      }
      return widget.child;
    }

    return switch (_step) {
      _Step.welcome => _welcome(),
      _Step.language => _language(),
      _Step.signIn || _Step.done => _signIn(),
    };
  }

  // ── Splash ───────────────────────────────────────────────────────────────

  Widget _splash({String? error}) {
    return SplashPage(
      data: V2SplashData(
        progress: _startupProgress,
        statusLabel: _startupLabel,
        errorLabel: error,
      ),
      onRetry: _boot,
    );
  }

  // ── Account admission ────────────────────────────────────────────────────

  Widget _accountPending(BuildContext context) {
    final c = OColors.of(context);
    final error = _accountRetryError ?? _auth.accountError;
    return OScaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: OSpace.xl),
          child: OContent(
            maxWidth: 420,
            child: OCard(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    liveRegion: true,
                    child: Text(
                      'Confirming your account',
                      style: OType.h2.copyWith(color: c.text),
                    ),
                  ),
                  const SizedBox(height: OSpace.m),
                  if (error == null)
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: 'Confirming your account',
                            valueColor: AlwaysStoppedAnimation<Color>(c.accent),
                          ),
                        ),
                        const SizedBox(width: OSpace.m),
                        Expanded(
                          child: Text(
                            'This usually takes a moment.',
                            style: OType.bodySm.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    )
                  else
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: OType.bodySm.copyWith(color: c.danger),
                      ),
                    ),
                  const SizedBox(height: OSpace.l),
                  OButton(
                    label: _accountRetrying ? 'Checking…' : 'Try again',
                    loading: _accountRetrying,
                    onPressed: _accountRetrying || _accountSigningOut
                        ? null
                        : _retryAccount,
                  ),
                  const SizedBox(height: OSpace.xs),
                  // A rejected account is not a dead end: this is the only way
                  // to replace it without reinstalling the app.
                  Center(
                    child: OTextAction(
                      key: const Key('account-use-another'),
                      label: _accountSigningOut
                          ? 'Signing out…'
                          : 'Use another account',
                      onPressed: _accountRetrying || _accountSigningOut
                          ? null
                          : _signOutAccount,
                    ),
                  ),
                  const SizedBox(height: OSpace.s),
                  Text(
                    'Signed in as ${_auth.accountLabel}',
                    textAlign: TextAlign.center,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _retryAccount() async {
    setState(() {
      _accountRetrying = true;
      _accountRetryError = null;
    });
    try {
      await _auth.retryAccountLogin();
    } catch (_) {
      if (mounted) {
        setState(
          () => _accountRetryError =
              'Could not confirm your account. Check your connection and '
              'retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _accountRetrying = false);
    }
  }

  /// Leaves a rejected account and returns to sign-in, where another provider
  /// or account can be used. The session is only dropped after the auth layer
  /// confirms it, so a failed sign-out never looks like a success.
  Future<void> _signOutAccount() async {
    if (_accountSigningOut || _accountRetrying) return;
    setState(() {
      _accountSigningOut = true;
      _accountRetryError = null;
    });
    try {
      await _auth.signOut();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _accountSigningOut = false;
        _accountRetryError =
            'Could not sign out. Check your connection and retry.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _accountSigningOut = false;
      _paywallSeen = false;
      _signInError = null;
      _lastSignInAction = null;
      _step = _Step.signIn;
    });
  }

  // ── Welcome ──────────────────────────────────────────────────────────────

  Widget _welcome() {
    return OnboardingWelcomePage(
      busy: _welcomeBusy,
      error: _welcomeError,
      onGetStarted: _welcomeBusy ? null : _leaveWelcome,
    );
  }

  Future<void> _leaveWelcome() async {
    if (_welcomeBusy) return;
    setState(() {
      _welcomeBusy = true;
      _welcomeError = null;
    });
    try {
      await _store.markWelcomeSeen(widget.welcomeVersion);
      // Keep the app-wide first-run notice in step with this tour. It uses its
      // own key/version and must never block onboarding if it fails.
      try {
        await AppState.I.markWelcomeSeen();
      } catch (e) {
        Diag.swallow('onboarding.welcome_seen', e);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _welcomeBusy = false;
        _welcomeError = 'We could not save your choice. Try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _welcomeBusy = false;
      _languageReturn = _Step.welcome;
      _step = _Step.language;
    });
  }

  // ── Language & goal ──────────────────────────────────────────────────────

  Widget _language() {
    return LanguageGoalPage(
      data: V2LanguageGoalData(
        selectedLanguageId: _languageId,
        selectedGoalIds: _goalIds,
        loading: _savingChoices,
        error: _choicesError,
      ),
      onLanguageSelected: (id) => setState(() => _languageId = id),
      onGoalToggled: (id, selected) => setState(() {
        if (selected) {
          _goalIds.add(id);
        } else {
          _goalIds.remove(id);
        }
      }),
      onContinue: _savingChoices ? null : _continueFromLanguage,
      onRetry: _choicesError == null
          ? null
          : () => _continueFromLanguage(_languageId, _goalIds),
      onBack: _savingChoices
          ? null
          : () => setState(() => _step = _languageReturn),
    );
  }

  Future<void> _continueFromLanguage(
    String languageId,
    Set<String> goalIds,
  ) async {
    if (_savingChoices) return;
    setState(() {
      _savingChoices = true;
      _choicesError = null;
    });
    try {
      await _store.saveChoices(languageId: languageId, goalIds: goalIds);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savingChoices = false;
        _choicesError = 'We could not save your choices. Try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _savingChoices = false;
      _languageId = languageId;
      _goalIds = Set.of(goalIds);
      _step = _Step.signIn;
    });
    // Persist the choice as the voice/assistant language too, so the picker is
    // a real preference rather than a label.
    await AppState.I.setVoiceLanguage(languageId);
  }

  // ── Sign-in ──────────────────────────────────────────────────────────────

  Widget _signIn() {
    return SignInPage(
      data: V2SignInData(loading: _signInBusy, error: _signInError),
      onGoogle: _signInBusy ? null : _signInWithGoogle,
      onPhone: _signInBusy ? null : _startPhoneSignIn,
      // Retry only exists when there is an attempt to repeat.
      onRetry: _signInBusy || _lastSignInAction == null ? null : _retrySignIn,
      onBack: _signInBusy ? null : () => _setLanguageBackToSignIn(),
    );
  }

  /// Back from sign-in goes to the language step, which then returns here.
  void _setLanguageBackToSignIn() {
    setState(() {
      _languageReturn = _Step.signIn;
      _step = _Step.language;
    });
  }

  Future<void> _retrySignIn() async {
    if (_signInBusy) return;
    final action = _lastSignInAction;
    if (action != null) await action();
  }

  Future<void> _signInWithGoogle() async {
    if (_signInBusy) return;
    setState(() {
      _signInBusy = true;
      _signInError = null;
      _lastSignInAction = _signInWithGoogle;
    });
    String? error;
    try {
      error = await _auth.authenticateSocial('google.com', AuthIntent.signIn);
    } catch (failure) {
      error = authError(failure);
    }
    if (!mounted) return;
    setState(() {
      _signInBusy = false;
      _signInError = (error == null || error == 'cancelled') ? null : error;
    });
  }

  Future<void> _startPhoneSignIn() async {
    if (_signInBusy) return;
    setState(() {
      _signInBusy = true;
      _signInError = null;
      _lastSignInAction = _startPhoneSignIn;
    });

    final PhoneAuthFlow flow;
    try {
      flow = _auth.createPhoneFlow(AuthIntent.signIn);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _signInBusy = false;
        _signInError = authError(failure);
      });
      return;
    }

    bool? result;
    try {
      result = await Navigator.of(context, rootNavigator: true).push<bool>(
        DialogRoute<bool>(
          context: context,
          barrierDismissible: false,
          // The dialog owns and disposes the flow.
          builder: (_) => AuthPhoneDialog(flow: flow),
        ),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _signInBusy = false;
        _signInError = authError(failure);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _signInBusy = false;
      if (result != true) _signInError = null;
    });
  }

  // ── Paywall ──────────────────────────────────────────────────────────────

  Widget _paywall() {
    return PaywallPage(
      data: V2PaywallData(
        plans: _paywallPlans(),
        selectedPlanId: _selectedPlanId,
        currency: _currencyId == 'inr' ? V2Currency.inr : V2Currency.usd,
        period: _paywallPeriod,
        purchasing: _purchasing,
        error: _paywallError,
        testModeNote: _testStore
            ? 'Test mode: purchases are simulated and never charge you.'
            : null,
      ),
      onPlanSelected: _purchasing
          ? null
          : (id) => setState(() => _selectedPlanId = id),
      onCurrencyChanged: _purchasing ? null : _setCurrency,
      onPeriodChanged: _purchasing
          ? null
          : (period) => setState(() => _paywallPeriod = period),
      // The period travels with the request: a yearly selection must buy the
      // yearly SKU, never the monthly one.
      onPurchase: _purchasing ? null : _purchasePlan,
      onStartTrial: _purchasing ? null : _startTrial,
      onContinueFree: _purchasing ? null : _finishPaywall,
      onRetry: _purchasing || _paywallError == null ? null : _retryPurchase,
      onRestorePurchases: _purchasing || widget.restorePurchases == null
          ? null
          : _restorePaywall,
      onClose: _purchasing ? null : _finishPaywall,
    );
  }

  /// The canonical cards, carrying the store's localised prices and whether
  /// Play sells each period. Falls back to the product-spec prices only when
  /// the store has not answered.
  List<V2PlanOption> _paywallPlans() {
    const base = V2PaywallData();
    final play = PlayBillingService.I;
    // Only Play's own purchase path can be gated by Play's catalogue; a
    // RevenueCat build may sell a package Play does not list here.
    final playCatalogue = !RevenueCatBilling.I.available;
    return [
      for (final plan in base.plans)
        plan.withStore(
          monthlyPrice: play.productFor(plan.tier)?.price,
          yearlyPrice: play
              .productFor(plan.tier, period: OvidBillingPeriod.yearly)
              ?.price,
          currency:
              play.productFor(plan.tier)?.currencyCode ??
              play
                  .productFor(plan.tier, period: OvidBillingPeriod.yearly)
                  ?.currencyCode,
          monthlyAvailable: playCatalogue && play.loaded
              ? play.hasProduct(plan.tier)
              : null,
          yearlyAvailable: playCatalogue && play.loaded
              ? play.hasProduct(plan.tier, period: OvidBillingPeriod.yearly)
              : null,
        ),
    ];
  }

  /// Runs the purchase for [planId] and [period]. A caller that only wired the
  /// monthly [V2OnboardingGate.purchase] seam cannot buy yearly: it returns
  /// false instead of quietly buying the monthly SKU.
  Future<bool> _buyForPeriod(String planId, V2PaywallPeriod period) {
    final billingPeriod = period == V2PaywallPeriod.yearly
        ? OvidBillingPeriod.yearly
        : OvidBillingPeriod.monthly;
    final periodAware = widget.purchaseForPeriod;
    if (periodAware != null) return periodAware(planId, billingPeriod);
    if (billingPeriod == OvidBillingPeriod.monthly) return _purchase(planId);
    return Future.value(false);
  }

  Future<void> _purchasePlan(V2PaywallPurchase purchase) =>
      _runPurchase(purchase.planId, purchase.period);

  void _retryPurchase() => _runPurchase(_selectedPlanId, _paywallPeriod);

  Future<void> _runPurchase(String planId, V2PaywallPeriod period) async {
    if (_purchasing) return;
    setState(() {
      _purchasing = true;
      _paywallError = null;
    });
    try {
      await _buyForPeriod(planId, period);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _purchasing = false;
        _paywallError =
            'The purchase could not be completed. Try again, or continue '
            'with the Free plan.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _purchasing = false;
      _paywallSeen = true;
      _step = _Step.done;
    });
  }

  Future<V2PaywallRestoreResult> _restorePaywall() async {
    final restore = widget.restorePurchases;
    if (restore == null) return V2PaywallRestoreResult.failed;
    try {
      return await restore();
    } catch (_) {
      return V2PaywallRestoreResult.failed;
    }
  }

  /// Switches the displayed currency and writes the choice to disk. The view
  /// changes immediately; a failed write is reported instead of pretending the
  /// preference will survive a restart.
  Future<void> _setCurrency(V2Currency currency) async {
    final id = currency.name;
    if (id == _currencyId) return;
    setState(() => _currencyId = id);
    try {
      await _store.saveCurrency(id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Could not save your currency choice.')),
      );
    }
  }

  Future<void> _startTrial(String planId) async {
    if (_purchasing) return;
    // The Free tier is not a purchase; it just continues into the app.
    if (planId == 'free') {
      _finishPaywall();
      return;
    }
    setState(() {
      _purchasing = true;
      _paywallError = null;
    });
    try {
      // The result is intentionally not turned into a local entitlement: the
      // billing layer owns that. Either way the user continues; nothing here
      // claims a purchase happened.
      await _purchase(planId);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _purchasing = false;
        _paywallError =
            'The purchase could not be completed. Try again, or continue '
            'with the Free plan.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _purchasing = false;
      _paywallSeen = true;
      _step = _Step.done;
    });
  }

  void _finishPaywall() {
    setState(() {
      _paywallSeen = true;
      _step = _Step.done;
    });
  }
}
