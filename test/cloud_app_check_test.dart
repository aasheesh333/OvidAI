import 'dart:async';

// FlutterFire exposes its native boundary fixtures from transitive packages.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud_app_check.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  const channel = MethodChannel('plugins.flutter.io/firebase_app_check');
  final calls = <MethodCall>[];
  String? token = 'sdk-attestation';
  setUpAll(() async {
    await Firebase.initializeApp();
  });
  setUp(() {
    calls.clear();
    token = 'sdk-attestation';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'FirebaseAppCheck#getToken') return token;
          if (call.method == 'FirebaseAppCheck#registerTokenListener') {
            return 'test-token-events';
          }
          return null;
        });
  });

  test(
    'production SDK accessor waits for boot, shares activation, sends Play Integrity',
    () async {
      final boot = Completer<void>();
      final check = CloudAppCheck(
        initializeFirebase: () => boot.future,
        activatedByFirebase: () => false,
      );
      final first = check.getToken();
      final second = check.getToken();
      expect(calls, isEmpty);
      boot.complete();
      expect(await first, 'sdk-attestation');
      expect(await second, 'sdk-attestation');
      final activations = calls.where(
        (c) => c.method == 'FirebaseAppCheck#activate',
      );
      expect(activations.length, 1);
      expect(activations.single.arguments['androidProvider'], 'playIntegrity');
      expect(
        calls.where((c) => c.method == 'FirebaseAppCheck#getToken').length,
        2,
      );
    },
  );

  test(
    'reuses Firebase-owned activation and rejects an empty SDK token',
    () async {
      final check = CloudAppCheck(
        initializeFirebase: () async {},
        activatedByFirebase: () => true,
      );
      token = null;
      await expectLater(
        check.getToken(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('App Check'),
          ),
        ),
      );
      expect(
        calls.where((c) => c.method == 'FirebaseAppCheck#activate'),
        isEmpty,
      );
      token = 'retry-attestation';
      expect(await check.getToken(), 'retry-attestation');
    },
  );

  test(
    'failed initialization is retryable rather than cached forever',
    () async {
      var attempts = 0;
      final check = CloudAppCheck(
        initializeFirebase: () async {
          if (++attempts == 1) throw StateError('boot failed');
        },
        activatedByFirebase: () => false,
      );
      await expectLater(check.getToken(), throwsA(isA<Exception>()));
      expect(await check.getToken(), 'sdk-attestation');
      expect(attempts, 2);
    },
  );
}
