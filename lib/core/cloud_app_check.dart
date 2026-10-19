import 'package:firebase_app_check/firebase_app_check.dart';

import 'firebase_service.dart';

/// OVID_APPCHECK — the single build switch for Firebase App Check
/// (Play Integrity attestation) on every cloud call.
///
/// Default **false**: the app is distributed outside Google Play for now, so
/// Play Integrity cannot attest it. With the switch off the app never
/// activates FirebaseAppCheck, never requests a token, never sends the
/// `X-Firebase-AppCheck` header, and never fails a request for lack of one.
/// The Firebase ID token (`Authorization: Bearer`) remains mandatory.
///
/// Build with `--dart-define=OVID_APPCHECK=true` to restore Play Integrity
/// attestation (Play-distributed builds). The servers must agree: the gateway
/// reads `OVID_APPCHECK_MODE` (required | optional | off) and the Python
/// mint/account services read `APPCHECK_ENABLED`.
///
/// Every App Check caller goes through [CloudAppCheck]; grep `kOvidAppCheck`
/// to find the remaining direct gates (FirebaseService activation and the
/// AccountService provider).
const bool kOvidAppCheck = bool.fromEnvironment('OVID_APPCHECK');

/// Owns cloud attestation activation when Firebase's account feature is off.
/// Firebase boot remains owned by FirebaseService; every caller waits for it.
class CloudAppCheck {
  CloudAppCheck({
    required this.initializeFirebase,
    required this.activatedByFirebase,
    this.enabled = kOvidAppCheck,
  });

  /// The one process-wide instance (one activation, one token cache). Lazy,
  /// so merely importing this file never touches Firebase.
  static final CloudAppCheck shared = CloudAppCheck(
    initializeFirebase: () => FirebaseService.I.initialize(),
    activatedByFirebase: () => FirebaseService.I.accountService.enabled,
  );

  final Future<void> Function() initializeFirebase;
  final bool Function() activatedByFirebase;

  /// False unless the build opted in with `OVID_APPCHECK=true`.
  final bool enabled;
  Future<void>? _initialization;

  /// The token getter to hand to a cloud client, or null when App Check is
  /// off. Clients treat a null provider as "send no attestation header and
  /// do not require one".
  Future<String?> Function()? get provider => enabled ? getToken : null;

  Future<void> _initialize() async {
    await initializeFirebase();
    if (!activatedByFirebase()) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
      );
    }
  }

  /// Null when App Check is disabled (nothing is activated or requested).
  /// When enabled, a token or [AppCheckUnavailable].
  Future<String?> getToken({bool forceRefresh = false}) async {
    if (!enabled) return null;
    try {
      try {
        await (_initialization ??= _initialize());
      } catch (_) {
        _initialization = null;
        rethrow;
      }
      final token = await FirebaseAppCheck.instance.getToken(forceRefresh);
      if (token == null || token.trim().isEmpty) {
        throw const AppCheckUnavailable();
      }
      return token;
    } catch (_) {
      throw const AppCheckUnavailable();
    }
  }
}

class AppCheckUnavailable implements Exception {
  const AppCheckUnavailable();
  @override
  String toString() =>
      'App Check could not verify this app. Restart the app and retry.';
}
