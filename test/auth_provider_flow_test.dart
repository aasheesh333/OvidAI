import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/auth_identity.dart';

class TestUser extends Fake implements User {
  TestUser(this.uid, this.ids);
  @override
  final String uid;
  final List<String> ids;
  int links = 0;
  int reauths = 0;
  Object? failure;
  String? nativeProvider;
  @override
  Future<UserCredential> linkWithProvider(AuthProvider provider) async {
    nativeProvider = provider.providerId;
    links++;
    return TestResult(this);
  }

  @override
  Future<UserCredential> reauthenticateWithProvider(
    AuthProvider provider,
  ) async {
    nativeProvider = provider.providerId;
    reauths++;
    return TestResult(this);
  }

  @override
  bool get isAnonymous => false;
  @override
  List<UserInfo> get providerData => ids.map(TestProvider.new).toList();
  @override
  Future<UserCredential> linkWithCredential(AuthCredential credential) async {
    links++;
    if (failure != null) throw failure!;
    return TestResult(this);
  }

  @override
  Future<UserCredential> reauthenticateWithCredential(
    AuthCredential credential,
  ) async {
    reauths++;
    if (failure != null) throw failure!;
    return TestResult(this);
  }

  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'token';
}

class TestProvider extends Fake implements UserInfo {
  TestProvider(this.providerId);
  @override
  final String providerId;
}

class TestResult extends Fake implements UserCredential {
  TestResult(this.user);
  @override
  final User user;
}

class TestAuth extends Fake implements FirebaseAuth {
  @override
  User? currentUser;
  int signIns = 0;
  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    signIns++;
    throw FirebaseAuthException(code: 'operation-not-allowed');
  }
}

void main() {
  test(
    'native cancellation and SMS quota/configuration errors remain distinct',
    () {
      expect(
        authError(PlatformException(code: 'sign_in_canceled')),
        'cancelled',
      );
      expect(
        authError(FirebaseAuthException(code: 'quota-exceeded')),
        contains('quota'),
      );
      expect(
        authError(FirebaseAuthException(code: 'too-many-requests')),
        contains('Wait'),
      );
      expect(
        authError(FirebaseAuthException(code: 'app-not-authorized')),
        contains('App verification failed'),
      );
      expect(
        authError(FirebaseAuthException(code: 'network-request-failed')),
        contains('connection'),
      );
    },
  );
  test(
    'each allowlisted native provider uses UID-bound SDK link and reauth',
    () async {
      for (final id in [
        'github.com',
        'apple.com',
        'microsoft.com',
        'facebook.com',
        'twitter.com',
        'yahoo.com',
      ]) {
        final user = TestUser('alice', [id]);
        final auth = TestAuth()..currentUser = user;
        final identity = AuthIdentity(
          auth: () => auth,
          providers: AuthProviders(socialIds: id),
          googleCredential: () async => throw StateError('not Google'),
        );
        expect(await identity.social(id, AuthIntent.reauthenticate), isNull);
        expect(await identity.social(id, AuthIntent.link), isNull);
        expect(user.nativeProvider, id);
        expect(await identity.social(id, AuthIntent.reauthenticate), isNull);
        expect(user.nativeProvider, id);
        expect(user.links, 1);
        expect(user.reauths, 2);
        expect(auth.signIns, 0);
      }
    },
  );
  test('phone link and reauth retain UID; stale target is rejected', () async {
    final user = TestUser('alice', ['phone']);
    final auth = TestAuth()..currentUser = user;
    final identity = AuthIdentity(
      auth: () => auth,
      providers: AuthProviders(phone: true),
      googleCredential: () async => null,
    );
    final credential = PhoneAuthProvider.credential(
      verificationId: 'id',
      smsCode: '123456',
    );
    await identity.phone(credential, AuthIntent.reauthenticate, 'alice');
    await identity.phone(credential, AuthIntent.link, 'alice');
    await identity.phone(credential, AuthIntent.reauthenticate, 'alice');
    expect(user.links, 1);
    expect(user.reauths, 2);
    expect(auth.signIns, 0);
    await expectLater(
      identity.phone(credential, AuthIntent.link, 'bob'),
      throwsA(isA<FirebaseAuthException>()),
    );
    expect(user.links, 1);
  });
  test(
    'collision never signs into another account or destroys legacy credentials',
    () async {
      final user = TestUser('alice', ['password', 'phone']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'token'),
      );
      await identity.phone(
        PhoneAuthProvider.credential(verificationId: 'old', smsCode: '123456'),
        AuthIntent.reauthenticate,
        'alice',
      );
      user.failure = FirebaseAuthException(code: 'credential-already-in-use');
      expect(
        await identity.social('google.com', AuthIntent.link),
        contains('another account'),
      );
      expect(auth.currentUser?.uid, 'alice');
      expect(auth.signIns, 0);
      expect(user.ids, ['password', 'phone']);
    },
  );
  test('wrong provider identity fails reauth and never signs in', () async {
    final user = TestUser('alice', ['google.com'])
      ..failure = FirebaseAuthException(code: 'user-mismatch');
    final auth = TestAuth()..currentUser = user;
    final identity = AuthIdentity(
      auth: () => auth,
      providers: AuthProviders(),
      googleCredential: () async =>
          GoogleAuthProvider.credential(idToken: 'bob'),
    );
    expect(
      await identity.social('google.com', AuthIntent.reauthenticate),
      contains('different account'),
    );
    expect(auth.signIns, 0);
  });
  test('cancelled Google picker cannot later link its credential', () async {
    final user = TestUser('alice', ['phone']);
    final auth = TestAuth()..currentUser = user;
    final picker = Completer<AuthCredential?>();
    final identity = AuthIdentity(
      auth: () => auth,
      providers: AuthProviders(),
      googleCredential: () => picker.future,
    );
    await identity.phone(
      PhoneAuthProvider.credential(verificationId: 'old', smsCode: '123456'),
      AuthIntent.reauthenticate,
      'alice',
    );
    final pending = identity.social('google.com', AuthIntent.link);
    identity.cancelPending();
    picker.complete(GoogleAuthProvider.credential(idToken: 'token'));
    expect(await pending, contains('account changed'));
    expect(user.links, 0);
  });
  test(
    'allowlist excludes unknown/password providers and disabled Google/phone',
    () {
      final registry = AuthProviders(
        socialIds: 'github.com,password,unknown, apple.com,github.com',
        google: false,
        phone: false,
      );
      expect(registry.enabled.map((p) => p.id), ['github.com', 'apple.com']);
      expect(registry.isEnabled('password'), isFalse);
    },
  );
  test(
    'link cannot mutate a replacement UID after Google picker returns',
    () async {
      final alice = TestUser('alice', ['phone']);
      final bob = TestUser('bob', ['google.com']);
      final auth = TestAuth()..currentUser = alice;
      final picker = Completer<AuthCredential?>();
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () => picker.future,
      );
      await identity.phone(
        PhoneAuthProvider.credential(verificationId: 'old', smsCode: '123456'),
        AuthIntent.reauthenticate,
        'alice',
      );
      final pending = identity.social('google.com', AuthIntent.link);
      auth.currentUser = bob;
      picker.complete(GoogleAuthProvider.credential(idToken: 'token'));
      expect(await pending, contains('account changed'));
      expect(alice.links, 0);
      expect(bob.links, 0);
      expect(auth.signIns, 0);
    },
  );
  test(
    'linked Google wins over legacy password for reauth without replacement sign-in',
    () async {
      final user = TestUser('alice', ['password', 'google.com']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'token'),
      );
      expect(
        await identity.social('google.com', AuthIntent.reauthenticate),
        isNull,
      );
      expect(user.reauths, 1);
      expect(auth.signIns, 0);
      expect(user.links, 0);
    },
  );
  test(
    'disabled config never launches provider and Firebase disabled error survives',
    () async {
      final auth = TestAuth();
      var picks = 0;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async {
          picks++;
          return GoogleAuthProvider.credential(idToken: 'token');
        },
      );
      expect(
        await identity.social('github.com', AuthIntent.signIn),
        contains('not configured'),
      );
      expect(picks, 0);
      expect(
        await identity.social('google.com', AuthIntent.signIn),
        contains('not enabled'),
      );
    },
  );
}
