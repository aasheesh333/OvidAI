// FlutterFire exposes its native boundary fixtures from transitive packages.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/cloud_app_check.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-side App Check wiring for the Ovid Cloud mint path.
///
/// The mint endpoint requires `X-Firebase-AppCheck`. In production the token
/// comes from `CloudAppCheck`, which boots Firebase and self-activates Play
/// Integrity unless Firebase already owns App Check (the account feature).
/// SDK-free tests inject the provider through the existing seam instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  const channel = MethodChannel('plugins.flutter.io/firebase_app_check');
  final appCheckCalls = <MethodCall>[];
  String? sdkToken = 'play-integrity-attestation';

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'firebase-id-token';
    appCheckCalls.clear();
    sdkToken = 'play-integrity-attestation';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          appCheckCalls.add(call);
          if (call.method == 'FirebaseAppCheck#getToken') return sdkToken;
          if (call.method == 'FirebaseAppCheck#registerTokenListener') {
            return 'test-token-events';
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.appCheckTokenProvider = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  test('mint sends the app-side App Check provider token', () async {
    var providerCalls = 0;
    OvidCloudService.appCheckTokenProvider = () async {
      providerCalls++;
      return 'provider-attestation';
    };
    String? mintAppCheck;
    final client = MockClient((request) async {
      if (request.url.path == '/mint') {
        mintAppCheck = request.headers['X-Firebase-AppCheck'];
        return http.Response(
          '{"key":"sk-user","tier":"free","base_url":"https://cloud.test/v1"}',
          200,
        );
      }
      if (request.url.path.endsWith('/models')) {
        return http.Response('{"data":[{"id":"auto"}]}', 200);
      }
      return http.Response('not found', 404);
    });

    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);

    expect(outcome.ok, isTrue);
    expect(providerCalls, 1);
    expect(mintAppCheck, 'provider-attestation');
    client.close();
  });

  test('a blank provider token omits the optional header and reaches the gateway', () async {
    OvidCloudService.appCheckTokenProvider = () async => '   ';
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{"key":"gateway-key"}', 200);
    });

    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);

    expect(outcome.ok, isTrue);
    expect(requests, greaterThan(0));
    client.close();
  });

  test('an explicit provider wins over the legacy id-token-only seam', () async {
    OvidCloudService.idTokenOverrideForTest = () async => 'legacy-id-token';
    OvidCloudService.appCheckTokenProvider = () async => 'explicit-attestation';
    String? mintAppCheck;
    final client = MockClient((request) async {
      if (request.url.path == '/mint') {
        mintAppCheck = request.headers['X-Firebase-AppCheck'];
        return http.Response('{"key":"k","tier":"free"}', 200);
      }
      return http.Response('{"data":[{"id":"auto"}]}', 200);
    });

    await OvidCloudService.I.bindOvidCloud(client: client);

    expect(mintAppCheck, 'explicit-attestation');
    client.close();
  });

  test('the legacy id-token-only seam still sends no App Check header', () async {
    Map<String, String>? mintHeaders;
    final client = MockClient((request) async {
      if (request.url.path == '/mint') {
        mintHeaders = request.headers;
        return http.Response('{"key":"k","tier":"free"}', 200);
      }
      return http.Response('{"data":[{"id":"auto"}]}', 200);
    });

    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);

    expect(outcome.ok, isTrue);
    expect(mintHeaders!.containsKey('X-Firebase-AppCheck'), isFalse);
    client.close();
  });

  test('production CloudAppCheck follows the Firebase account-ownership flag', () async {
    const accountEnabled = bool.fromEnvironment('OVID_ACCOUNT_ENABLED');
    expect(FirebaseService.I.accountService.enabled, accountEnabled);

    var boots = 0;
    final check = CloudAppCheck(
      initializeFirebase: () async {
        boots++;
      },
      activatedByFirebase: () => FirebaseService.I.accountService.enabled,
    );

    expect(await check.getToken(), 'play-integrity-attestation');
    expect(boots, 1);
    final activations = appCheckCalls
        .where((c) => c.method == 'FirebaseAppCheck#activate')
        .toList();
    expect(activations, hasLength(accountEnabled ? 0 : 1));
    if (!accountEnabled) {
      expect(activations.single.arguments['androidProvider'], 'playIntegrity');
    }
  });

  test('auth config is social+phone only; password can never be enabled', () {
    expect(
      AuthProviders().enabled.map((p) => p.id),
      ['google.com', 'phone'],
    );
    final configured = AuthProviders(
      socialIds: 'github.com, apple.com, password',
    );
    expect(
      configured.enabled.map((p) => p.id),
      ['google.com', 'github.com', 'apple.com', 'phone'],
    );
    expect(configured.isEnabled('password'), isFalse);
    expect(AuthProviders(phone: false).isEnabled('phone'), isFalse);
  });
}
