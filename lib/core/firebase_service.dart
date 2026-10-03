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
import 'image_studio.dart';

/// Firebase bootstrap + auth + consent-gated telemetry.
///
/// Design:
///  • Google/email identity; LoginGate requires a nonanonymous account.
///  • Analytics & Crashlytics are OFF until the user explicitly opts in
///    (Play-policy: data collection requires consent). Consent is persisted.
///  • google-services.json is injected at build time via the
///    GOOGLE_SERVICES_JSON CI secret — never committed to the repo.
///  • If Firebase is not configured (debug/local without the file), readiness
///    reports initialization failure while all feature methods stay safe.
class FirebaseService extends ChangeNotifier {
  FirebaseService._({this._initializeApp, Future<void> Function()? configure})
    : _configureForTest = configure;

  static final FirebaseService I = FirebaseService._();

  @visibleForTesting
  FirebaseService.forTest({
    required Future<void> Function() initializeApp,
    required Future<void> Function() configure,
  }) : this._(initializeApp: initializeApp, configure: configure);

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
      isSignedIn && (!accountService.enabled || _accountSession.ready);
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

  StreamSubscription<User?>? _authSub;
  Future<void>? _initialization;
  final Future<void> Function()? _initializeApp;
  final Future<void> Function()? _configureForTest;

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
        notifyListeners();
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
      _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onUser);
      _onUser(FirebaseAuth.instance.currentUser);

      // Route Flutter + platform errors to Crashlytics only when consented.
      if (_consentGiven) _attachCrashHandlers();
      notifyListeners();
    } catch (_) {
      _available = false;
      rethrow;
    }
  }

  void _onUser(User? user) {
    final changed = _user?.uid != user?.uid;
    if (changed) ImageStudio.I.clearCapabilities();
    _user = user;
    if (changed || user == null) _accountSession.clear();
    notifyListeners();
    if (isSignedIn && accountService.enabled && !_accountSession.ready) {
      unawaited(retryAccountLogin());
    }
  }

  Future<void> retryAccountLogin() async {
    final u = _user;
    if (u == null || u.isAnonymous || !accountService.enabled) return;
    await _accountSession.bind(u.uid, () async {
      final result = await accountService.acknowledgeLogin();
      if (result.allowsLogin) lastDeletionReceipt = null;
    });
    notifyListeners();
  }

  bool get usesPassword =>
      _user?.providerData.any((p) => p.providerId == 'password') ?? false;

  /// Reauthenticate the current UID, never sign in as a replacement account.
  Future<String?> reauthenticate({String? password}) async {
    final u = _user;
    if (u == null || u.isAnonymous) return 'Please sign in first.';
    try {
      AuthCredential credential;
      if (usesPassword) {
        if (password == null || password.isEmpty || u.email == null) {
          return 'Enter your password.';
        }
        credential = EmailAuthProvider.credential(
          email: u.email!,
          password: password,
        );
      } else if (u.providerData.any((p) => p.providerId == 'google.com')) {
        final google = await GoogleSignIn().signIn();
        if (google == null) return 'cancelled';
        final tokens = await google.authentication;
        credential = GoogleAuthProvider.credential(
          accessToken: tokens.accessToken,
          idToken: tokens.idToken,
        );
      } else {
        return 'This sign-in provider does not support account deletion in this build.';
      }
      await u.reauthenticateWithCredential(credential);
      await u.getIdToken(true);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Could not verify your identity.';
    } catch (_) {
      return 'Could not verify your identity. Please retry.';
    }
  }

  Future<AccountDeletion> requestAccountDeletion(String requestId) async {
    final result = await accountService.requestDeletion(requestId);
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

  /// Email/password sign-in. Returns null on success, else an error message.
  Future<String?> signInWithEmail(String email, String password) async {
    if (!_available) return 'Sign-in is not configured in this build.';
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Sign-in failed (${e.code}).';
    } catch (e) {
      return 'Sign-in failed: $e';
    }
  }

  /// The current user's Firebase ID token (JWT), or null when signed out.
  /// Used to authenticate to the Ovid Cloud mint endpoint, which verifies it
  /// against Google's public keys. [forceRefresh] re-mints a near-expiry token.
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final u = _user ?? FirebaseAuth.instance.currentUser;
    if (u == null) return null;
    try {
      return await u.getIdToken(forceRefresh);
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
    if (!_available) return 'Sign-in is not configured in this build.';
    try {
      final google = await GoogleSignIn().signIn();
      if (google == null) return 'cancelled';
      final auth = await google.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: auth.accessToken,
        idToken: auth.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Google sign-in failed (${e.code}).';
    } catch (e) {
      return 'Google sign-in failed: $e';
    }
  }

  /// Email/password account creation. Returns null on success, else error.
  Future<String?> signUpWithEmail(String email, String password) async {
    if (!_available) return 'Sign-in is not configured in this build.';
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Sign-up failed (${e.code}).';
    } catch (e) {
      return 'Sign-up failed: $e';
    }
  }

  Future<String?> sendPasswordReset(String email) async {
    if (!_available) return 'Sign-in is not configured in this build.';
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Could not send reset email.';
    } catch (e) {
      return 'Could not send reset email: $e';
    }
  }

  Future<void> signOut() async {
    ImageStudio.I.clearCapabilities();
    if (!_available) return;
    _accountSession.clear();
    _user = null;
    notifyListeners();
    await FirebaseAuth.instance.signOut();
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      Diag.swallow('firebase.google_signout', e);
    }
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
