import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'diag.dart';
import 'account_service.dart';
import 'account_session.dart';
import 'state.dart';
import 'image_studio.dart';
import 'auth_identity.dart';
import 'auth_phone_flow.dart';
import 'auth_providers.dart';

/// Firebase bootstrap + auth + consent-gated telemetry.
///
/// Design:
///  • Configured social/phone identity; LoginGate requires a nonanonymous account.
///  • Analytics & Crashlytics are OFF until the user explicitly opts in
///    (Play-policy: data collection requires consent). Consent is persisted.
///  • google-services.json is injected at build time via the
///    GOOGLE_SERVICES_JSON CI secret — never committed to the repo.
///  • If Firebase is not configured (debug/local without the file), readiness
///    reports initialization failure while all feature methods stay safe.
class FirebaseService extends ChangeNotifier {
  FirebaseService._({
    this._initializeApp,
    Future<void> Function()? configure,
    AuthIdentity? identity,
    User? initialUser,
    Stream<User?>? userChanges,
  }) : _configureForTest = configure,
       _userChangesForTest = userChanges,
       _authIdentity = identity,
       _user = initialUser {
    identity?.observeUser(initialUser);
  }

  static final FirebaseService I = FirebaseService._();

  @visibleForTesting
  FirebaseService.forTest({
    required Future<void> Function() initializeApp,
    required Future<void> Function() configure,
    AuthIdentity? identity,
    User? initialUser,
    Stream<User?>? userChanges,
  }) : this._(
         initializeApp: initializeApp,
         configure: configure,
         identity: identity,
          initialUser: initialUser,
          userChanges: userChanges,
       );

  static const _consentKey = 'ovid_telemetry_consent'; // 'yes' | 'no' | null

  bool _available = false;
  bool _consentGiven = false;
  bool _consentAsked = false;
  User? _user;

  bool get isAvailable => _available;
  bool get consentGiven => _consentGiven;
  bool get consentAsked => _consentAsked;
  bool get isSignedIn => _user != null && !_user!.isAnonymous;
  final _accountSession = AccountSession();
  bool get accountReady =>
      isSignedIn &&
      AppState.I.sessionAccountReady &&
      AppState.I.sessionAccountId == 'firebase:$uid' &&
      (!accountService.enabled || _accountSession.ready);
  String? get accountError => _accountSession.error;
  late final accountService = AccountService(
    idToken: (force) => getIdToken(forceRefresh: force),
    appCheck: () => FirebaseAppCheck.instance.getToken(),
    currentUid: () => uid,
  );
  AccountDeletion? lastDeletionReceipt;
  User? get user => _user;
  String? get email => _user?.email;
  String? get displayName => _user?.displayName;
  String? get photoUrl => _user?.photoURL;
  String? get uid => _user?.uid;
  bool get emailVerified => _user?.emailVerified ?? false;
  String? get phoneNumber => _user?.phoneNumber;
  final authProviders = AuthProviders();
  AuthIdentity? _authIdentity;
  AuthIdentity get _identity => _authIdentity ??= AuthIdentity(
    auth: () => FirebaseAuth.instance,
    providers: authProviders,
    googleCredential: () async {
      final google = await GoogleSignIn().signIn();
      if (google == null) return null;
      final tokens = await google.authentication;
      return GoogleAuthProvider.credential(
        accessToken: tokens.accessToken,
        idToken: tokens.idToken,
      );
    },
  );
  Set<String> get linkedProviderIds =>
      _user?.providerData.map((p) => p.providerId).toSet() ?? {};
  List<AuthProviderCapability> get reauthProviders => authProviders.enabled
      .where((p) => linkedProviderIds.contains(p.id))
      .toList();
  int _authRevision = 0;

  StreamSubscription<User?>? _authSub;
  Future<void>? _initialization;
  final Future<void> Function()? _initializeApp;
  final Future<void> Function()? _configureForTest;
  final Stream<User?>? _userChangesForTest;

  /// Initialize Firebase if a config is present. Safe to call on all builds.
  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    late final Future<void> attempt;
    attempt = _initialize().catchError((Object error, StackTrace stack) {
      if (identical(_initialization, attempt)) _initialization = null;
      Error.throwWithStackTrace(error, stack);
    });
    _initialization = attempt;
    return attempt;
  }

  Future<void> _initialize() async {
    try {
      if (_initializeApp != null) {
        await _initializeApp();
      } else {
        await Firebase.initializeApp();
      }
      _available = true;
    } catch (e) {
      // Readiness reports the failure and may retry; the app remains usable.
      _available = false;
      debugPrint('Firebase unavailable: $e');
      rethrow;
    }

    if (_configureForTest != null) {
      try {
        await _configureForTest();
        _authSub ??= _userChangesForTest?.listen((user) {
          unawaited(_onUser(user));
        });
        await _onUser(_user);
        return;
      } catch (_) {
        _available = false;
        rethrow;
      }
    }
    try {
      await _restoreConsent();

      if (accountService.enabled) {
        await FirebaseAppCheck.instance.activate(
          androidProvider: AndroidProvider.playIntegrity,
        );
      }
      _authSub ??= FirebaseAuth.instance.userChanges().listen((user) {
        unawaited(_onUser(user));
      });
      await _onUser(_identity.currentUser);

      // Route Flutter + platform errors to Crashlytics only when consented.
      if (_consentGiven) _attachCrashHandlers();
      notifyListeners();
    } catch (_) {
      _available = false;
      rethrow;
    }
  }

  Future<void> _onUser(User? user, {AuthIntent? intent}) async {
    _identity.observeUser(user);
    final changed = _user?.uid != user?.uid;
    if (changed) {
      _authRevision++;
    }
    // A successful reauthentication is a new image owner even for the same UID.
    // Keep the auth revision stable: an in-progress phone flow captures it.
    // Ordinary user/token refresh events have no intent and retain image work.
    if (changed ||
        user == null ||
        user.isAnonymous ||
        intent == AuthIntent.reauthenticate) {
      ImageStudio.I.bindAccount(null);
    }
    _user = user;
    if (changed || user == null) _accountSession.clear();
    final revision = _authRevision;
    // This boundary invalidates sessions/runs/search synchronously before any
    // auth listener can expose the replacement account.
    final transition = AppState.I.transitionSessionAccount(
      user == null || user.isAnonymous ? 'guest' : 'firebase:${user.uid}',
    );
    try {
      await transition;
    } catch (e) {
      Diag.swallow('account.sessions', e);
    }
    if (revision != _authRevision ||
        (intent != null && _identity.currentUser?.uid != user?.uid)) {
      return;
    }
    if (accountReady && ImageStudio.I.accountId != user?.uid) {
      ImageStudio.I.bindAccount(user!.uid);
      try {
        await ImageStudio.I.loadReceipts();
      } catch (e) {
        Diag.swallow('account.image_receipts', e);
      }
      if (revision != _authRevision) return;
    }
    notifyListeners();
    if (isSignedIn && accountService.enabled && !_accountSession.ready) {
      unawaited(retryAccountLogin());
    }
  }

  Future<void> retryAccountLogin() async {
    final u = _user;
    if (u == null || u.isAnonymous || !accountService.enabled) return;
    final revision = _authRevision;
    _accountSession.clear();
    ImageStudio.I.bindAccount(null);
    await AppState.I.transitionSessionAccount('firebase:${u.uid}');
    if (revision != _authRevision ||
        _user?.uid != u.uid ||
        !AppState.I.sessionAccountReady) {
      return;
    }
    await _accountSession.bind(u.uid, () async {
      final result = await accountService.acknowledgeLogin();
      if (revision == _authRevision && result.allowsLogin) {
        lastDeletionReceipt = null;
      }
    });
    if (revision != _authRevision) return;
    if (accountReady) {
      ImageStudio.I.bindAccount(u.uid);
      try {
        await ImageStudio.I.loadReceipts();
      } catch (e) {
        Diag.swallow('account.image_receipts', e);
      }
      if (revision != _authRevision) return;
    }
    notifyListeners();
  }

  Future<String?> authenticateSocial(
    String providerId,
    AuthIntent intent,
  ) async {
    if (!_available) return 'Sign-in is not configured in this build.';
    if (intent == AuthIntent.reauthenticate) _identity.invalidateProof();
    final error = await _identity.social(providerId, intent);
    if (error == null) {
      await _onUser(_identity.currentUser, intent: intent);
    }
    return error;
  }

  PhoneAuthFlow createPhoneFlow(AuthIntent intent) {
    final expectedUid = _identity.currentUser?.uid;
    if (intent == AuthIntent.reauthenticate) _identity.invalidateProof();
    return PhoneAuthFlow(
      currentUid: () => _identity.currentUser?.uid,
      currentSession: () => _authRevision,
      verify: (number, token, callbacks) async {
        if (!_available || !authProviders.isEnabled('phone')) {
          throw FirebaseAuthException(code: 'provider-not-configured');
        }
        if (_identity.currentUser?.uid != expectedUid) {
          throw FirebaseAuthException(code: 'account-changed');
        }
        if (intent == AuthIntent.link) _identity.requireLinkProof();
        if (intent == AuthIntent.reauthenticate && number != phoneNumber) {
          throw FirebaseAuthException(code: 'user-mismatch');
        }
        await _identity.auth().verifyPhoneNumber(
          phoneNumber: number,
          timeout: const Duration(seconds: 60),
          forceResendingToken: token,
          verificationCompleted: callbacks.completed,
          verificationFailed: callbacks.failed,
          codeSent: callbacks.codeSent,
          codeAutoRetrievalTimeout: callbacks.timedOut,
        );
      },
      apply: (credential) async {
        await _identity.phone(credential, intent, expectedUid);
        await _onUser(_identity.currentUser, intent: intent);
      },
    );
  }

  Future<AccountDeletion> requestAccountDeletion(String requestId) async {
    if (uid == null ||
        uid != _identity.currentUser?.uid ||
        !_identity.deletionAuthorized) {
      throw const AccountException(
        'Verify the current account before requesting deletion.',
      );
    }
    _identity.consumeDeletionProof();
    final revision = _authRevision;
    final result = await accountService.requestDeletion(requestId);
    if (revision != _authRevision) return result;
    if (result.isPending) {
      lastDeletionReceipt = result;
      // The retained server request is the success criterion; signing out only
      // prevents this device's old session from continuing to use the account.
      try {
        await signOut();
      } catch (e) {
        // Server acceptance remains true even if local provider sign-out fails.
        Diag.swallow('account.signout_after_request', e);
      }
    }
    return result;
  }

  Future<void> _restoreConsent() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_consentKey);
    _consentAsked = v != null;
    _consentGiven = v == 'yes';
    await _applyTelemetryFlags();
  }

  /// Record the user's telemetry choice and apply it.
  Future<void> setConsent(bool allow) async {
    _consentGiven = allow;
    _consentAsked = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_consentKey, allow ? 'yes' : 'no');
    await _applyTelemetryFlags();
    if (allow) _attachCrashHandlers();
    notifyListeners();
  }

  Future<void> _applyTelemetryFlags() async {
    if (!_available) return;
    try {
      await FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(
        _consentGiven,
      );
      await FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(
        _consentGiven,
      );
    } catch (e) {
      Diag.swallow('firebase_service', e);
    }
  }

  bool _crashHandlersAttached = false;
  void _attachCrashHandlers() {
    if (_crashHandlersAttached || !_available) return;
    _crashHandlersAttached = true;
    FlutterError.onError = (details) {
      FirebaseCrashlytics.instance.recordFlutterFatalError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  }

  /// The current user's Firebase ID token (JWT), or null when signed out.
  /// Used to authenticate to the Ovid Cloud mint endpoint, which verifies it
  /// against Google's public keys. [forceRefresh] re-mints a near-expiry token.
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final revision = _authRevision;
    final u = _user ?? FirebaseAuth.instance.currentUser;
    if (u == null) return null;
    try {
      final token = await u.getIdToken(forceRefresh);
      return revision == _authRevision && _user?.uid == u.uid ? token : null;
    } catch (e) {
      debugPrint('getIdToken failed: $e');
      return null;
    }
  }

  /// Update the signed-in user's display name (FAANG-style editable profile).
  /// Returns null on success, else an error message.
  Future<String?> updateDisplayName(String name) async {
    final u = _user ?? FirebaseAuth.instance.currentUser;
    if (u == null) return 'Not signed in.';
    try {
      await u.updateDisplayName(name.trim());
      await u.reload();
      _user = FirebaseAuth.instance.currentUser;
      notifyListeners();
      return null;
    } catch (e) {
      return 'Could not update name: $e';
    }
  }

  /// Google sign-in (B7): native Google account picker → Firebase credential.
  /// Returns null on success, else an error message; 'cancelled' means the
  /// user closed the picker (not an error to surface loudly).
  Future<String?> signInWithGoogle() async {
    return authenticateSocial('google.com', AuthIntent.signIn);
  }

  Future<void> signOut() async {
    // SDK credential submission cannot be aborted. Do not race it with signout.
    if (_identity.busy) return;
    _identity.cancelPending();
    _authRevision++;
    ImageStudio.I.bindAccount(null);
    if (!_available) return;
    _accountSession.clear();
    _user = null;
    final transition = AppState.I.transitionSessionAccount('guest');
    notifyListeners();
    await transition;
    await FirebaseAuth.instance.signOut();
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      Diag.swallow('firebase.google_signout', e);
    }
  }

  /// Barrier-safe local sign-out for the all-store reset.
  ///
  /// Clears the local account state (identity, user, account session, image
  /// ownership) and notifies listeners, but never awaits
  /// [AppState.transitionSessionAccount]. The public [signOut] cannot run inside
  /// the settings barrier: its guest transition captures the in-progress
  /// `_settingsOperation` and awaits the very barrier that is calling it, which
  /// deadlocks. The reset owner invokes this instead and wipes the AppState
  /// session namespace directly.
  Future<void> signOutLocal() async {
    _identity.cancelPending();
    _identity.observeUser(null);
    _authRevision++;
    ImageStudio.I.bindAccount(null);
    _accountSession.clear();
    _user = null;
    notifyListeners();
  }

  /// Lightweight analytics event — only fires when consent is given.
  Future<void> logEvent(String name, [Map<String, Object>? params]) async {
    if (!_available || !_consentGiven) return;
    try {
      await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    } catch (e) {
      Diag.swallow('firebase_service', e);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
