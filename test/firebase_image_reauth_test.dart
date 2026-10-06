import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

import 'auth_provider_flow_test.dart' show TestAuth, TestUser;

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;

  @override
  Future<String> getApplicationSupportPath() async => directory.path;
}

class _User extends TestUser {
  _User(String uid) : super(uid, ['google.com', 'phone']);

  @override
  String get phoneNumber => '+14155550100';
}

class _Auth extends TestAuth {
  late PhoneVerificationCompleted completePhone;
  late PhoneCodeSent sendCode;

  @override
  Future<void> verifyPhoneNumber({
    String? phoneNumber,
    PhoneMultiFactorInfo? multiFactorInfo,
    required PhoneVerificationCompleted verificationCompleted,
    required PhoneVerificationFailed verificationFailed,
    required PhoneCodeSent codeSent,
    required PhoneCodeAutoRetrievalTimeout codeAutoRetrievalTimeout,
    String? autoRetrievedSmsCodeForTesting,
    Duration timeout = const Duration(seconds: 30),
    int? forceResendingToken,
    MultiFactorSession? multiFactorSession,
  }) async {
    expect(phoneNumber, '+14155550100');
    completePhone = verificationCompleted;
    sendCode = codeSent;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = ImageStudio.I;
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late AppState app;
  late _User user;
  late _Auth auth;
  late StreamController<User?> changes;
  late Future<AuthCredential?> Function() googleCredential;
  late FirebaseService service;
  late ImageReceiptStore store;

  setUpAll(() {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('firebase-image-reauth-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    SessionSearch.dbPathOverrideForTest = '${directory.path}/search.db';
    SessionLedger.rootOverrideForTest = directory;
    app = AppState.createForTest(memoryStore: MemoryStore(directory));
    app.suspendCoalescedPersistenceForTest = true;
    images.bindAccount(null);
    store = ImageReceiptStore(directory: () async => directory);
    await store.reserve(
      ImageRequestRecord(
        accountId: 'alice',
        requestId: 'reauth-image-request-1234',
        fingerprint: 'a' * 64,
      ),
      isCurrent: () => true,
      canSubmit: () => true,
    );
    user = _User('alice');
    auth = _Auth()..currentUser = user;
    changes = StreamController<User?>.broadcast(sync: true);
    googleCredential = () async =>
        GoogleAuthProvider.credential(idToken: 'fixture');
    service = FirebaseService.forTest(
      initializeApp: () async {},
      configure: () async {},
      identity: AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () => googleCredential(),
      ),
      initialUser: user,
      userChanges: changes.stream,
    );
    await service.initialize();
    expect(service.accountReady, isTrue);
    expect(images.receipts.single.accountId, 'alice');
  });

  tearDown(() async {
    service.dispose();
    await changes.close();
    images.bindAccount(null);
    await app.awaitPendingSessionWritesForTest();
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  Future<void> observeUser(User? next) async {
    final observed = Completer<void>();
    void listener() {
      if (service.uid == next?.uid && !observed.isCompleted) {
        observed.complete();
      }
    }

    service.addListener(listener);
    try {
      auth.currentUser = next;
      changes.add(next);
      await observed.future;
    } finally {
      service.removeListener(listener);
    }
  }

  test('same-UID social reauth revokes old images and reloads receipts', () async {
    final generation = images.accountGeneration;
    final owners = <String?>[];
    void observe() {
      owners.add(images.accountId);
      if (images.accountId != null) expect(service.accountReady, isTrue);
    }

    images.addListener(observe);
    addTearDown(() => images.removeListener(observe));
    expect(
      await service.authenticateSocial('google.com', AuthIntent.reauthenticate),
      isNull,
    );
    expect(images.accountGeneration, greaterThan(generation));
    expect(owners.first, isNull);
    expect(images.accountId, 'alice');
    expect(images.receipts.single.requestId, 'reauth-image-request-1234');
    expect(images.receiptLoadError, isNull);
  });

  for (final automatic in [false, true]) {
    test('same-UID ${automatic ? 'automatic' : 'SMS'} phone reauth succeeds and fences old images', () async {
      final generation = images.accountGeneration;
      final flow = service.createPhoneFlow(AuthIntent.reauthenticate);
      addTearDown(flow.dispose);
      await flow.send(user.phoneNumber);
      expect(flow.error, isNull);
      expect(images.accountGeneration, generation);
      // Firebase can refresh the user while verification is in progress.
      await observeUser(user);
      expect(images.accountGeneration, generation);
      if (automatic) {
        final finished = Completer<void>();
        flow.addListener(() {
          if ((flow.succeeded || flow.error != null) && !finished.isCompleted) {
            finished.complete();
          }
        });
        auth.completePhone(
          PhoneAuthProvider.credential(
            verificationId: 'fixture',
            smsCode: '123456',
          ),
        );
        await finished.future;
      } else {
        auth.sendCode('fixture', null);
        await flow.submit('123456');
      }
      expect(flow.error, isNull);
      expect(flow.succeeded, isTrue);
      expect(images.accountGeneration, greaterThan(generation));
      expect(images.accountId, 'alice');
      expect(images.receipts.single.requestId, 'reauth-image-request-1234');
    });
  }

  test('old recovery response cannot publish after same-UID reauth', () async {
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final pending = http.runWithClient(
      () => images.recover(
        requestId: 'reauth-image-request-1234',
        headers: {'Authorization': 'Bearer fixture'},
      ),
      () => MockClient((request) {
        expect(request.method, 'GET');
        requested.complete();
        return response.future;
      }),
    );
    final rejected = expectLater(pending, throwsA(isA<ImageStudioError>()));
    await requested.future;
    await service.authenticateSocial('google.com', AuthIntent.reauthenticate);
    response.complete(
      http.Response(
        jsonEncode({
          'receipt': {
            'account_id': 'alice',
            'request_id': 'reauth-image-request-1234',
            'fingerprint': 'a' * 64,
            'state': 'confirmed',
            'charged': '0.01',
          },
        }),
        200,
      ),
    );
    await rejected;
    expect(images.receipts.single.receipt, isNull);
    expect((await store.list('alice')).single.receipt, isNull);
  });

  test('ordinary same-UID user refreshes preserve image ownership', () async {
    final generation = images.accountGeneration;
    final receipts = images.receipts;
    await observeUser(_User('alice'));
    await observeUser(auth.currentUser);
    expect(images.accountGeneration, generation);
    expect(images.receipts, same(receipts));
  });

  for (final cancelled in [false, true]) {
    test('${cancelled ? 'cancelled' : 'failed'} social reauth preserves image ownership', () async {
      final generation = images.accountGeneration;
      if (cancelled) {
        googleCredential = () async => null;
      } else {
        user.failure = FirebaseAuthException(code: 'user-mismatch');
      }
      expect(
        await service.authenticateSocial('google.com', AuthIntent.reauthenticate),
        isNotNull,
      );
      expect(images.accountGeneration, generation);
      expect(images.receipts.single.accountId, 'alice');
    });
  }

  test('failed phone code keeps its session valid for successful retry', () async {
    final generation = images.accountGeneration;
    final flow = service.createPhoneFlow(AuthIntent.reauthenticate);
    addTearDown(flow.dispose);
    await flow.send(user.phoneNumber);
    auth.sendCode('fixture', null);
    user.failure = FirebaseAuthException(code: 'invalid-verification-code');
    await flow.submit('111111');
    expect(flow.succeeded, isFalse);
    expect(images.accountGeneration, generation);
    user.failure = null;
    await flow.submit('123456');
    expect(flow.succeeded, isTrue);
    expect(images.accountGeneration, greaterThan(generation));
  });

  for (final backToAlice in [false, true]) {
    test('stale social completion after ${backToAlice ? 'A-B-A' : 'account switch'} cannot rebind images', () async {
      final credential = Completer<AuthCredential?>();
      googleCredential = () => credential.future;
      final pending = service.authenticateSocial(
        'google.com',
        AuthIntent.reauthenticate,
      );
      await observeUser(_User('bob'));
      if (backToAlice) await observeUser(user);
      final generation = images.accountGeneration;
      credential.complete(GoogleAuthProvider.credential(idToken: 'stale'));
      expect(await pending, contains('account changed'));
      expect(images.accountGeneration, generation);
      expect(images.accountId, backToAlice ? 'alice' : 'bob');
    });
  }

  test('phone code from an earlier A-B-A session cannot reauthenticate', () async {
    final flow = service.createPhoneFlow(AuthIntent.reauthenticate);
    addTearDown(flow.dispose);
    await flow.send(user.phoneNumber);
    auth.sendCode('fixture', null);
    await observeUser(_User('bob'));
    await observeUser(user);
    final generation = images.accountGeneration;
    await flow.submit('123456');
    expect(flow.succeeded, isFalse);
    expect(flow.error, contains('account changed'));
    expect(images.accountGeneration, generation);
  });

  test('reauth revokes images but cannot bind before session readiness', () async {
    await app.transitionSessionAccount('guest');
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = '${directory.path}/missing/search.db';
    expect(
      await service.authenticateSocial('google.com', AuthIntent.reauthenticate),
      isNull,
    );
    expect(service.accountReady, isFalse);
    expect(images.accountId, isNull);
    expect(images.receipts, isEmpty);
    // A later ready identity event can load the correct journal.
    SessionSearch.dbPathOverrideForTest = '${directory.path}/search.db';
    await observeUser(user);
    expect(service.accountReady, isTrue);
    expect(images.accountId, 'alice');
    expect(images.receipts.single.accountId, 'alice');
  });
}
