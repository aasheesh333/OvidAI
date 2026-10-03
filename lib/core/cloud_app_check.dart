import 'package:firebase_app_check/firebase_app_check.dart';

/// Owns cloud attestation activation when Firebase's account feature is off.
/// Firebase boot remains owned by FirebaseService; every caller waits for it.
class CloudAppCheck {
  CloudAppCheck({
    required this.initializeFirebase,
    required this.activatedByFirebase,
  });

  final Future<void> Function() initializeFirebase;
  final bool Function() activatedByFirebase;
  Future<void>? _initialization;

  Future<void> _initialize() async {
    await initializeFirebase();
    if (!activatedByFirebase()) {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.playIntegrity,
      );
    }
  }

  Future<String> getToken() async {
    try {
      try {
        await (_initialization ??= _initialize());
      } catch (_) {
        _initialization = null;
        rethrow;
      }
      final token = await FirebaseAppCheck.instance.getToken();
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
