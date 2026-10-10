// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  test(
    'registered sync and collaboration share real CloudAppCheck activation when account flag is off',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await Firebase.initializeApp();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/firebase_app_check'),
            (call) async {
              calls.add(call);
              if (call.method == 'FirebaseAppCheck#getToken') {
                return 'sdk-attestation';
              }
              if (call.method == 'FirebaseAppCheck#registerTokenListener') {
                return 'token-events';
              }
              return null;
            },
          );
      final app = AppState.createForTest();
      final firebase = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
      );
      expect(firebase.accountService.enabled, false);
      app.registerProductionAccountFeatures(firebaseService: firebase);
      expect(await app.privateSync!.appCheckToken(), 'sdk-attestation');
      expect(await app.collaboration!.appCheckToken(), 'sdk-attestation');
      final activations = calls.where(
        (c) => c.method == 'FirebaseAppCheck#activate',
      );
      expect(activations, hasLength(1));
      expect(activations.single.arguments['androidProvider'], 'playIntegrity');
      expect(
        calls.where((c) => c.method == 'FirebaseAppCheck#getToken'),
        hasLength(2),
      );
      await app.privateSync!.release();
      await app.collaboration!.release();
      AppState.resetTestInstance();
    },
  );
}
