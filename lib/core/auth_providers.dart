import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

class AuthProviderCapability {
  const AuthProviderCapability(this.id, this.label);
  final String id;
  final String label;
  bool get isPhone => id == 'phone';
}

/// Build-time declaration of providers configured by the project owner.
/// This is not a live Firebase Console capability probe. Server errors remain
/// authoritative. Unknown IDs (including password) are always excluded.
class AuthProviders {
  AuthProviders({
    String socialIds = const String.fromEnvironment(
      'OVID_AUTH_SOCIAL_PROVIDERS',
    ),
    bool google = const bool.fromEnvironment(
      'OVID_AUTH_GOOGLE',
      defaultValue: true,
    ),
    bool phone = const bool.fromEnvironment(
      'OVID_AUTH_PHONE',
      defaultValue: true,
    ),
  }) : enabled = List.unmodifiable([
         if (google) const AuthProviderCapability('google.com', 'Google'),
         for (final id in socialIds.split(',').map((s) => s.trim()).toSet())
           if (_social.containsKey(id))
             AuthProviderCapability(id, _social[id]!),
         if (phone) const AuthProviderCapability('phone', 'Phone'),
       ]);

  static const _social = {
    'github.com': 'GitHub',
    'apple.com': 'Apple',
    'microsoft.com': 'Microsoft',
    'facebook.com': 'Facebook',
    'twitter.com': 'Twitter',
    'yahoo.com': 'Yahoo',
  };
  final List<AuthProviderCapability> enabled;
  bool isEnabled(String id) => enabled.any((p) => p.id == id);

  /// Friendly label for any configured or legacy provider id.
  ///
  /// Resolves the same display name used by the auth picker (`Google`,
  /// `Phone`, `GitHub`, …), including the legacy `password` provider which is
  /// not a configurable social provider but can still appear in the signed-in
  /// user's `providerData`. Unknown ids fall back to a Title-Cased slug.
  static String labelFor(String id) {
    switch (id) {
      case 'google.com':
        return 'Google';
      case 'phone':
        return 'Phone';
      case 'password':
        return 'Password (legacy)';
    }
    final social = _social[id];
    if (social != null) return social;
    final base = id.contains('.') ? id.split('.').first : id;
    if (base.isEmpty) return id;
    return base[0].toUpperCase() + base.substring(1);
  }
}

const legacyAuthMigrationHelp =
    'Previously used a password? Verify an already linked social provider or phone '
    'before linking another method. If none is available, contact Ovid support for '
    'identity-verified account recovery. Creating a new account will not migrate '
    'your existing data.';

String authError(Object error) {
  if (error is PlatformException) {
    if (error.code == 'sign_in_canceled' || error.code == 'sign_in_cancelled') {
      return 'cancelled';
    }
    if (error.code == 'network_error') {
      return 'Network unavailable. Check your connection and retry.';
    }
  }
  if (error is! FirebaseAuthException) {
    return 'Authentication could not finish. Please retry.';
  }
  return switch (error.code) {
    'trusted-migration-required' => legacyAuthMigrationHelp,
    'identity-proof-required' =>
      'Verify a pre-existing linked provider again before linking or requesting deletion.',
    'operation-not-allowed' ||
    'provider-disabled' ||
    'admin-restricted-operation' =>
      'This provider is not enabled for this Firebase project. Contact Ovid support or choose another configured method.',
    'provider-not-configured' =>
      'This provider is not configured in this build.',
    'account-changed' =>
      'The account changed. Start verification again for the current account.',
    'auth-busy' =>
      'Another authentication request is still finishing. Please wait.',
    'user-mismatch' =>
      'That identity belongs to a different account. Use the provider linked to this account.',
    'account-exists-with-different-credential' || 'email-already-in-use' =>
      'An account already exists with another sign-in method. Sign in with that linked method, then open Account and explicitly link this provider. $legacyAuthMigrationHelp',
    'credential-already-in-use' =>
      'This identity is linked to another account. Your accounts have not been merged. Sign in to the intended account with its linked method, then retry linking an unused identity.',
    'provider-already-linked' =>
      'This provider is already linked. Use its existing identity to verify this account.',
    'requires-recent-login' =>
      'Verify this account with a linked provider, then retry. $legacyAuthMigrationHelp',
    'invalid-verification-code' =>
      'Incorrect verification code. Check the SMS and retry.',
    'session-expired' ||
    'invalid-verification-id' ||
    'code-expired' => 'The verification code expired. Request a new code.',
    'invalid-phone-number' =>
      'Enter a valid phone number with country code, such as +14155550100.',
    'too-many-requests' => 'Too many attempts. Wait before trying again.',
    'quota-exceeded' =>
      'SMS quota is currently exhausted. Try later or use another configured provider.',
    'network-request-failed' =>
      'Network unavailable. Check your connection and retry.',
    'app-not-authorized' ||
    'invalid-app-credential' ||
    'missing-client-identifier' ||
    'captcha-check-failed' =>
      'App verification failed. This build or device may not be authorized for this Firebase project. Contact Ovid support.',
    'user-disabled' => 'This account has been disabled. Contact Ovid support.',
    'cancelled' ||
    'web-context-cancelled' ||
    'popup-closed-by-user' ||
    'canceled' => 'cancelled',
    _ =>
      'Authentication failed (${error.code}). Please retry or contact Ovid support.',
  };
}
