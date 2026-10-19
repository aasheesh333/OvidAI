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
    'registered collaboration never touches App Check when OVID_APPCHECK is off',
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
              return null;
            },
          );
      final app = AppState.createForTest();
      final firebase = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
      );
      app.registerProductionAccountFeatures(firebaseService: firebase);
      // OVID_APPCHECK defaults to false: no provider is wired at all, so the
      // collaboration client sends no X-Firebase-AppCheck header and never
      // fails a request for lack of one.
      expect(app.collaboration!.appCheckToken, isNull);
      expect(calls, isEmpty);
      await app.collaboration!.release();
      AppState.resetTestInstance();
    },
  );
}
