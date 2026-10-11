import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PR-1: Ovid Cloud model catalog and connection recovery (F-001…F-007).
http.Response mint([String key = 'scoped-key']) => http.Response(
  '{"key":"$key","tier":"free","base_url":"https://example.test/v1"}',
  200,
);
http.Response catalog([List<String> ids = const ['auto', 'manual-model']]) =>
    http.Response(
      jsonEncode({
        'data': [
          for (final id in ids) {'id': id},
        ],
      }),
      200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'account-a';
    OvidCloudService.appCheckTokenProvider = () async => 'attestation';
  });
  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.appCheckTokenProvider = null;
    OvidCloudService.httpClientFactoryForTest = null;
    OvidCloudService.forceRefreshIdTokenOverrideForTest = null;
    OvidCloudService.clockForTest = DateTime.now;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  ProviderConfig cloudProvider() =>
      AppState.I.providerById(AppState.ovidCloudProviderId)!;

  group('F-002 picker', () {
    testWidgets('failed catalog still lists Auto and persisted models', (
      tester,
    ) async {
      cloudProvider().models
        ..clear()
        ..addAll(['auto', 'manual-model']);
      OvidCloudService.I.setConnectionForTest(
        AppState.I,
        const CloudConnectionState(
          CloudConnectionStatus.failed,
          error: 'Ovid Cloud model catalog unavailable (503). Retry.',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.tap(find.byIcon(Icons.unfold_more).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloud-catalog-stale')), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ListTile), matching: find.text('Auto')),
        findsWidgets,
      );
      expect(find.text('manual-model'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.ensureVisible(find.text('manual-model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('manual-model'));
      await tester.pumpAndSettle();
      expect(AppState.I.activeSession!.model, 'manual-model');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rows are disabled only while a mint is in flight', (
      tester,
    ) async {
      OvidCloudService.I.setConnectionForTest(
        AppState.I,
        const CloudConnectionState(CloudConnectionStatus.connecting),
      );
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.tap(find.byIcon(Icons.unfold_more).first);
      await tester.pump(const Duration(milliseconds: 500));
      final auto = tester.widget<ListTile>(
        find
            .ancestor(of: find.text('Auto'), matching: find.byType(ListTile))
            .first,
      );
      expect(auto.enabled, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('F-007 providers tile', () {
    testWidgets('failed connection shows the reason and Retry connection', (
      tester,
    ) async {
      var mints = 0;
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((request) async {
            if (request.url.path == '/mint') {
              mints++;
              return mint();
            }
            return catalog();
          });
      OvidCloudService.I.setConnectionForTest(
        AppState.I,
        const CloudConnectionState(
          CloudConnectionStatus.failed,
          error: 'Ovid Cloud is busy (429). Retry in a moment.',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
      );
      await tester.pump();
      expect(
        find.text('Ovid Cloud is busy (429). Retry in a moment.'),
        findsOneWidget,
      );
      expect(find.textContaining('Signed in'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('ovid-cloud-retry-connection')),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(mints, 1);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      expect(find.textContaining('Signed in · 2 models'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ovid-cloud-refresh-models')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('expired session offers Sign out', (tester) async {
      OvidCloudService.I.setConnectionForTest(
        AppState.I,
        const CloudConnectionState(
          CloudConnectionStatus.failed,
          error: 'Your session expired. Sign in again to use Ovid Cloud.',
          mintStatus: MintStatus.sessionExpired,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ovid-cloud-sign-out')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('F-001 rejected key rotation', () {
    test('a re-mint returning the rejected key publishes repairing', () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/mint') return mint();
        return http.Response('{"error":{"code":"key_invalid"}}', 401);
      });
      // The freshly minted key is rejected by the catalog: the same flight
      // asks the gateway once to rotate it, and gets the same key back.
      final outcome = await OvidCloudService.I.ensureConnected(client: client);
      final state = OvidCloudService.I.connectionFor(AppState.I);
      expect(outcome.status, MintStatus.repairing);
      expect(state.status, CloudConnectionStatus.failed);
      expect(state.mintStatus, MintStatus.repairing);
      expect(state.error, contains('being repaired'));
      // No second catalog call with the dead key; another Retry asks the
      // gateway to rotate again instead of looping on the catalog.
      expect(paths, ['/mint', '/v1/models', '/mint']);
      await OvidCloudService.I.ensureConnected(client: client);
      expect(paths, ['/mint', '/v1/models', '/mint', '/mint']);
      expect(OvidCloudService.I.keyOwnedByCurrentAccount, isFalse);
      client.close();
    });
  });

  group('F-003 backoff and gateway header', () {
    test('a 503 from a modern gateway keeps the key', () async {
      var mints = 0;
      var models = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          mints++;
          return mint();
        }
        return ++models == 1
            ? http.Response(
                '{"error":{"code":"catalog_unavailable"}}',
                503,
                headers: {'x-ovid-gateway': '2'},
              )
            : catalog();
      });
      await OvidCloudService.I.ensureConnected(client: client);
      expect(OvidCloudService.I.keyOwnedByCurrentAccount, isTrue);
      expect(
        (await OvidCloudService.I.ensureConnected(client: client)).ok,
        isTrue,
      );
      expect(mints, 1);
      expect(models, 2);
      client.close();
    });

    test(
      'resume during a 503 storm makes at most one call per window',
      () async {
        var now = DateTime(2026, 10, 11, 12);
        OvidCloudService.clockForTest = () => now;
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          if (request.url.path == '/mint') return mint();
          return http.Response(
            '{"error":{"code":"catalog_unavailable"}}',
            503,
            headers: {'X-Ovid-Gateway': '2'},
          );
        });
        await OvidCloudService.I.ensureConnected(client: client);
        expect(calls, 2); // mint + catalog
        for (var i = 0; i < 10; i++) {
          await OvidCloudService.I.ensureConnectedOnResume(client: client);
        }
        expect(calls, 2);
        now = now.add(const Duration(seconds: 37));
        for (var i = 0; i < 10; i++) {
          await OvidCloudService.I.ensureConnectedOnResume(client: client);
        }
        expect(calls, 3); // one catalog retry with the kept key
        // The next window doubles (60–72 s).
        now = now.add(const Duration(seconds: 40));
        await OvidCloudService.I.ensureConnectedOnResume(client: client);
        expect(calls, 3);
        now = now.add(const Duration(seconds: 40));
        await OvidCloudService.I.ensureConnectedOnResume(client: client);
        expect(calls, 4);
        // An explicit Retry is never throttled.
        await OvidCloudService.I.ensureConnected(client: client);
        expect(calls, 5);
        client.close();
      },
    );
  });

  group('F-004 account switch', () {
    test('sign-out then B with /mint 402 leaves no Ovid Cloud key', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          return request.headers['Authorization'] == 'Bearer account-a'
              ? mint('key-of-a')
              : http.Response('limit', 402);
        }
        return catalog();
      });
      await OvidCloudService.I.ensureConnected(client: client);
      expect(cloudProvider().apiKey, 'key-of-a');
      expect(OvidCloudService.I.keyOwnedByCurrentAccount, isTrue);
      await FirebaseService.I.signOutLocal();
      expect(cloudProvider().apiKey, isEmpty);
      expect(OvidCloudService.I.keyOwnedByCurrentAccount, isFalse);
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      final outcome = await OvidCloudService.I.ensureConnected(client: client);
      expect(outcome.status, MintStatus.freeLimitReached);
      expect(cloudProvider().apiKey, isEmpty);
      expect(OvidCloudService.I.ownsKey('key-of-a'), isFalse);
      client.close();
    });

    test('a key bound for A is never owned by B', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          return request.headers['Authorization'] == 'Bearer account-a'
              ? mint('key-of-a')
              : http.Response('limit', 402);
        }
        return catalog();
      });
      await OvidCloudService.I.ensureConnected(client: client);
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      await OvidCloudService.I.ensureConnected(client: client);
      expect(OvidCloudService.I.keyOwnedByCurrentAccount, isFalse);
      expect(OvidCloudService.I.ownsKey(cloudProvider().cleanApiKey), isFalse);
      client.close();
    });
  });

  group('F-005 mint token refresh', () {
    test('/mint 401 retries once with a force-refreshed ID token', () async {
      var refreshes = 0;
      OvidCloudService.forceRefreshIdTokenOverrideForTest = () async {
        refreshes++;
        return 'account-a-refreshed';
      };
      final auth = <String?>[];
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          auth.add(request.headers['Authorization']);
          return request.headers['Authorization'] == 'Bearer account-a'
              ? http.Response('{"detail":"token expired"}', 401)
              : mint();
        }
        return catalog();
      });
      expect(
        (await OvidCloudService.I.ensureConnected(client: client)).ok,
        isTrue,
      );
      expect(refreshes, 1);
      expect(auth, ['Bearer account-a', 'Bearer account-a-refreshed']);
      client.close();
    });

    test('a persistent 401 asks to sign in again after one retry', () async {
      var mints = 0;
      final client = MockClient((request) async {
        mints++;
        return http.Response('{"detail":"invalid id token"}', 401);
      });
      final outcome = await OvidCloudService.I.ensureConnected(client: client);
      expect(mints, 2);
      expect(outcome.status, MintStatus.sessionExpired);
      expect(outcome.message, contains('Sign in again'));
      client.close();
    });

    test('an App Check failure asks to update from Google Play', () async {
      final client = MockClient(
        (request) async =>
            http.Response('{"detail":"missing app check token"}', 401),
      );
      final outcome = await OvidCloudService.I.ensureConnected(client: client);
      expect(outcome.status, MintStatus.deviceUnverified);
      expect(outcome.message, contains('Google Play'));
      client.close();
    });
  });

  group('F-006 orphaned model', () {
    test('a model that left the catalog falls back to Auto once', () async {
      final app = AppState.I;
      final provider = cloudProvider();
      provider.models
        ..clear()
        ..addAll(['auto', 'old-model']);
      app.setModel(AppState.ovidCloudProviderId, 'old-model · High');
      expect(app.lastSelectedModel, 'old-model · High');
      provider.models
        ..clear()
        ..addAll(['auto', 'new-model']);
      app.reconcileProviderModels(AppState.ovidCloudProviderId);
      expect(app.activeSession!.providerId, AppState.ovidCloudProviderId);
      expect(app.activeSession!.model, 'auto');
      expect(app.lastSelectedModel, 'auto');
      expect(
        app.ovidCloudModelFallbackNotice.value,
        'old-model is no longer available — switched to Auto.',
      );
      app.ovidCloudModelFallbackNotice.value = null;
      app.reconcileProviderModels(AppState.ovidCloudProviderId);
      expect(app.ovidCloudModelFallbackNotice.value, isNull);
    });
  });
}
