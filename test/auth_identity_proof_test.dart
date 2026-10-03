import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'auth_provider_flow_test.dart' show TestAuth, TestUser, TestResult;

class SignupAuth extends TestAuth {
  SignupAuth(this.newUser);
  final TestUser newUser;
  void Function(User)? onUser;
  @override
  Future<UserCredential> signInWithCredential(AuthCredential credential) async {
    currentUser = newUser;
    onUser?.call(newUser);
    return TestResult(newUser);
  }
}

void main() {
  test(
    'FirebaseService rejects consumed and switched-account deletion proof',
    () async {
      final user = TestUser('alice', ['google.com']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'old'),
      );
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        identity: identity,
        initialUser: user,
      );
      await service.initialize();
      expect(
        await service.authenticateSocial(
          'google.com',
          AuthIntent.reauthenticate,
        ),
        isNull,
      );
      identity.consumeDeletionProof();
      await expectLater(
        service.requestAccountDeletion('consumed'),
        throwsA(isA<AccountException>()),
      );
      expect(
        await service.authenticateSocial(
          'google.com',
          AuthIntent.reauthenticate,
        ),
        isNull,
      );
      auth.currentUser = TestUser('bob', ['google.com']);
      await expectLater(
        service.requestAccountDeletion('switched'),
        throwsA(isA<AccountException>()),
      );
      service.dispose();
    },
  );
  test(
    'FirebaseService refuses legacy link and deletion without UI mediation',
    () async {
      final user = TestUser('legacy', ['password']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'new'),
      );
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        identity: identity,
        initialUser: user,
      );
      await service.initialize();
      expect(
        await service.authenticateSocial('google.com', AuthIntent.link),
        contains('identity-verified account recovery'),
      );
      user.ids.add('google.com');
      expect(
        await service.authenticateSocial(
          'google.com',
          AuthIntent.reauthenticate,
        ),
        contains('identity-verified account recovery'),
      );
      await expectLater(
        service.requestAccountDeletion('request'),
        throwsA(isA<AccountException>()),
      );
      expect(user.links, 0);
      expect(user.reauths, 0);
      service.dispose();
    },
  );
  test(
    'legacy link then newly linked reauth cannot authorize deletion',
    () async {
      final user = TestUser('legacy', ['password']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'new'),
      );
      expect(
        await identity.social('google.com', AuthIntent.link),
        contains('identity-verified account recovery'),
      );
      expect(user.links, 0);
      // A providerData refresh must not promote a new identity to trusted proof.
      user.ids.add('google.com');
      identity.observeUser(user);
      expect(
        await identity.social('google.com', AuthIntent.reauthenticate),
        contains('identity-verified account recovery'),
      );
      expect(user.reauths, 0);
      expect(identity.deletionAuthorized, isFalse);
      expect(
        identity.consumeDeletionProof,
        throwsA(isA<FirebaseAuthException>()),
      );
    },
  );

  test(
    'fresh old-provider proof is required and consumed by linking',
    () async {
      final user = TestUser('social', ['google.com']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(socialIds: 'github.com'),
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'old'),
      );
      expect(
        await identity.social('github.com', AuthIntent.link),
        contains('Verify'),
      );
      expect(user.links, 0);
      expect(
        await identity.social('google.com', AuthIntent.reauthenticate),
        isNull,
      );
      expect(await identity.social('github.com', AuthIntent.link), isNull);
      expect(user.links, 1);
      expect(identity.deletionAuthorized, isFalse);
      user.ids.add('github.com');
      expect(
        await identity.social('github.com', AuthIntent.reauthenticate),
        isNull,
      );
      expect(identity.deletionAuthorized, isTrue);
      identity.consumeDeletionProof();
      expect(identity.deletionAuthorized, isFalse);
    },
  );

  test(
    'expired, cancelled, or switched-session proof cannot authorize link/deletion',
    () async {
      var now = DateTime.utc(2026);
      final user = TestUser('alice', ['google.com']);
      final auth = TestAuth()..currentUser = user;
      final identity = AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(socialIds: 'github.com'),
        now: () => now,
        googleCredential: () async =>
            GoogleAuthProvider.credential(idToken: 'old'),
      );
      await identity.social('google.com', AuthIntent.reauthenticate);
      now = now.add(const Duration(minutes: 6));
      expect(identity.deletionAuthorized, isFalse);
      expect(
        await identity.social('github.com', AuthIntent.link),
        contains('Verify'),
      );
      await identity.social('google.com', AuthIntent.reauthenticate);
      identity.cancelPending();
      expect(identity.deletionAuthorized, isFalse);
      await identity.social('google.com', AuthIntent.reauthenticate);
      auth.currentUser = TestUser('bob', ['google.com']);
      identity.observeUser(auth.currentUser);
      auth.currentUser = user;
      identity.observeUser(user);
      expect(identity.deletionAuthorized, isFalse);
      expect(
        await identity.social('github.com', AuthIntent.link),
        contains('Verify'),
      );
      expect(user.links, 0);
    },
  );

  test(
    'fresh social and phone accounts can authorize deletion after reauth',
    () async {
      for (final provider in ['google.com', 'phone']) {
        final user = TestUser('new-$provider', [provider]);
        final auth = SignupAuth(user);
        final identity = AuthIdentity(
          auth: () => auth,
          providers: AuthProviders(),
          googleCredential: () async =>
              GoogleAuthProvider.credential(idToken: 'new'),
        );
        auth.onUser = identity.observeUser;
        if (provider == 'phone') {
          await identity.phone(
            PhoneAuthProvider.credential(
              verificationId: 'signup',
              smsCode: '123456',
            ),
            AuthIntent.signIn,
            null,
          );
        } else {
          expect(await identity.social(provider, AuthIntent.signIn), isNull);
        }
        expect(identity.deletionAuthorized, isFalse);
        if (provider == 'phone') {
          await identity.phone(
            PhoneAuthProvider.credential(
              verificationId: 'id',
              smsCode: '123456',
            ),
            AuthIntent.reauthenticate,
            user.uid,
          );
        } else {
          expect(
            await identity.social(provider, AuthIntent.reauthenticate),
            isNull,
          );
        }
        expect(identity.deletionAuthorized, isTrue);
      }
    },
  );
}
