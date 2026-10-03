import 'package:firebase_auth/firebase_auth.dart';
import 'auth_providers.dart';

enum AuthIntent { signIn, link, reauthenticate }

/// Provider operations never recover collisions by signing in a replacement UID.
/// Firebase owns proof of the provider identity; email equality is not proof.
class AuthIdentity {
  AuthIdentity({
    required this.auth,
    required this.providers,
    required this.googleCredential,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  String? _sessionUid;
  final Set<String> _trusted = {};
  ({String uid, String provider, int generation, DateTime at})? _proof;

  /// Snapshot pre-existing methods once per session, never on provider refresh.
  void observeUser(User? user) {
    if (_sessionUid == user?.uid) return;
    _sessionUid = user?.uid;
    _trusted
      ..clear()
      ..addAll(
        user?.providerData
                .map((p) => p.providerId)
                .where(providers.isEnabled) ??
            <String>[],
      );
    cancelPending();
  }

  bool get deletionAuthorized {
    final user = auth().currentUser;
    observeUser(user);
    final proof = _proof;
    return proof != null &&
        proof.uid == user?.uid &&
        proof.generation == _generation &&
        _trusted.contains(proof.provider) &&
        user!.providerData.any((p) => p.providerId == proof.provider) &&
        _now().difference(proof.at) < const Duration(minutes: 5);
  }

  void consumeDeletionProof() {
    if (!deletionAuthorized) {
      throw FirebaseAuthException(code: 'identity-proof-required');
    }
    _proof = null;
  }

  void invalidateProof() => _proof = null;

  void requireLinkProof() {
    observeUser(auth().currentUser);
    if (_trusted.isEmpty) {
      throw FirebaseAuthException(code: 'trusted-migration-required');
    }
    if (!deletionAuthorized) {
      throw FirebaseAuthException(code: 'identity-proof-required');
    }
  }

  void _authorize(AuthIntent intent, String provider) {
    if (intent == AuthIntent.signIn) return;
    if (_trusted.isEmpty ||
        (intent == AuthIntent.reauthenticate && !_trusted.contains(provider))) {
      _proof = null;
      throw FirebaseAuthException(code: 'trusted-migration-required');
    }
    if (intent == AuthIntent.link) {
      requireLinkProof();
      consumeDeletionProof();
    }
    if (intent == AuthIntent.reauthenticate) _proof = null;
  }

  final FirebaseAuth Function() auth;
  final AuthProviders providers;
  final Future<AuthCredential?> Function() googleCredential;
  User? get currentUser => auth().currentUser;
  bool _busy = false;
  int _generation = 0;
  bool get busy => _busy;

  void cancelPending() {
    _generation++;
    _proof = null;
  }

  User? _target(AuthIntent intent, String providerId) {
    final user = auth().currentUser;
    if (intent == AuthIntent.signIn) {
      if (user != null) throw FirebaseAuthException(code: 'account-changed');
    } else {
      if (user == null || user.isAnonymous) {
        throw FirebaseAuthException(code: 'account-changed');
      }
      if (intent == AuthIntent.reauthenticate &&
          !user.providerData.any((p) => p.providerId == providerId)) {
        throw FirebaseAuthException(code: 'user-mismatch');
      }
    }
    return user;
  }

  void _check(User? target, int generation) {
    if (generation != _generation || auth().currentUser?.uid != target?.uid) {
      throw FirebaseAuthException(code: 'account-changed');
    }
  }

  Future<String?> social(String id, AuthIntent intent) async {
    if (!providers.isEnabled(id) || id == 'phone') {
      return authError(FirebaseAuthException(code: 'provider-not-configured'));
    }
    if (_busy) return authError(FirebaseAuthException(code: 'auth-busy'));
    observeUser(auth().currentUser);
    _busy = true;
    final generation = _generation;
    try {
      final target = _target(intent, id);
      final linkProof = intent == AuthIntent.link ? _proof : null;
      _authorize(intent, id);
      UserCredential result;
      if (id == 'google.com') {
        final credential = await googleCredential();
        if (credential == null) return 'cancelled';
        _check(target, generation);
        if (linkProof != null &&
            _now().difference(linkProof.at) >= const Duration(minutes: 5)) {
          throw FirebaseAuthException(code: 'identity-proof-required');
        }
        result = await _apply(target, intent, credential);
      } else {
        // Available in firebase_auth 5.5.4. Firebase performs native OAuth.
        final provider = OAuthProvider(id);
        _check(target, generation);
        result = switch (intent) {
          AuthIntent.signIn => await auth().signInWithProvider(provider),
          AuthIntent.link => await target!.linkWithProvider(provider),
          AuthIntent.reauthenticate => await target!.reauthenticateWithProvider(
            provider,
          ),
        };
      }
      await _finish(target, intent, result, generation, id);
      return null;
    } catch (e) {
      return authError(e);
    } finally {
      _busy = false;
    }
  }

  Future<void> phone(
    AuthCredential credential,
    AuthIntent intent,
    String? expectedUid,
  ) async {
    if (!providers.isEnabled('phone')) {
      throw FirebaseAuthException(code: 'provider-not-configured');
    }
    if (_busy) throw FirebaseAuthException(code: 'auth-busy');
    observeUser(auth().currentUser);
    _busy = true;
    final generation = _generation;
    try {
      final target = _target(intent, 'phone');
      if (target?.uid != expectedUid) {
        throw FirebaseAuthException(code: 'account-changed');
      }
      _check(target, generation);
      _authorize(intent, 'phone');
      final result = await _apply(target, intent, credential);
      await _finish(target, intent, result, generation, 'phone');
    } finally {
      _busy = false;
    }
  }

  Future<UserCredential> _apply(
    User? target,
    AuthIntent intent,
    AuthCredential credential,
  ) => switch (intent) {
    AuthIntent.signIn => auth().signInWithCredential(credential),
    AuthIntent.link => target!.linkWithCredential(credential),
    AuthIntent.reauthenticate => target!.reauthenticateWithCredential(
      credential,
    ),
  };

  Future<void> _finish(
    User? target,
    AuthIntent intent,
    UserCredential result,
    int generation,
    String provider,
  ) async {
    if (intent == AuthIntent.signIn) {
      // userChanges may report our successful sign-in before the SDK Future.
      final observedSignIn =
          _sessionUid == result.user?.uid && _generation == generation + 1;
      if ((generation != _generation && !observedSignIn) ||
          result.user == null ||
          auth().currentUser?.uid != result.user?.uid) {
        throw FirebaseAuthException(code: 'account-changed');
      }
      observeUser(result.user);
      return;
    }
    _check(target, generation);
    if (result.user?.uid != target!.uid) {
      throw FirebaseAuthException(code: 'user-mismatch');
    }
    if (intent == AuthIntent.reauthenticate) {
      await target.getIdToken(true);
      _check(target, generation);
      _proof = (
        uid: target.uid,
        provider: provider,
        generation: generation,
        at: _now(),
      );
    }
    if (intent == AuthIntent.link) _trusted.add(provider);
  }
}
