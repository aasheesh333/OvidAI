import 'dart:async';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Firebase bootstrap + auth + consent-gated telemetry.
///
/// Design:
///  • Optional sign-in (BYOK chat works without an account).
///  • Analytics & Crashlytics are OFF until the user explicitly opts in
///    (Play-policy: data collection requires consent). Consent is persisted.
///  • google-services.json is injected at build time via the
///    GOOGLE_SERVICES_JSON CI secret — never committed to the repo.
///  • If Firebase is not configured (debug/local without the file), every
///    method degrades to a safe no-op.
class FirebaseService extends ChangeNotifier {
  FirebaseService._();
  static final FirebaseService I = FirebaseService._();

  static const _consentKey = 'ovid_telemetry_consent'; // 'yes' | 'no' | null

  bool _available = false;
  bool _consentGiven = false;
  bool _consentAsked = false;
  User? _user;

  bool get isAvailable => _available;
  bool get consentGiven => _consentGiven;
  bool get consentAsked => _consentAsked;
  bool get isSignedIn => _user != null;
  User? get user => _user;
  String? get email => _user?.email;
  String? get displayName => _user?.displayName;

  StreamSubscription<User?>? _authSub;

  /// Initialize Firebase if a config is present. Safe to call on all builds.
  Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (e) {
      // No google-services.json (local debug) or init failure — run offline.
      _available = false;
      debugPrint('Firebase unavailable: $e');
      return;
    }

    await _restoreConsent();

    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      _user = user;
      notifyListeners();
    });
    _user = FirebaseAuth.instance.currentUser;

    // Route Flutter + platform errors to Crashlytics only when consented.
    if (_consentGiven) _attachCrashHandlers();
    notifyListeners();
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
    } catch (_) {}
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
    if (!_available) return;
    await FirebaseAuth.instance.signOut();
  }

  /// Lightweight analytics event — only fires when consent is given.
  Future<void> logEvent(String name, [Map<String, Object>? params]) async {
    if (!_available || !_consentGiven) return;
    try {
      await FirebaseAnalytics.instance.logEvent(name: name, parameters: params);
    } catch (_) {}
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }
}
