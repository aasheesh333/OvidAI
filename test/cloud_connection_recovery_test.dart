import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_login_gate_test.dart' show GateService;

http.Response mint([String key = 'scoped-key']) => http.Response(
  '{"key":"$key","tier":"free","base_url":"https://example.test/v1"}',
  200,
);
http.Response catalog() => http.Response(
  jsonEncode({
    'data': [
      {'id': 'auto'},
      {'id': 'manual-model'},
    ],
  }),
  200,
);

/// `GET /cloud/v1/models`: the gateway's own manual-model answer.
///
/// It is a separate call from the catalog (Firebase-authenticated, not the
/// scoped key), so these mocks route it explicitly instead of folding it into
/// the catalog sequence they count.
bool isModelAccess(http.BaseRequest request) =>
    request.url.path == '/cloud/v1/models';

http.Response modelAccess({bool manual = false, String tier = 'free'}) =>
    http.Response(
      jsonEncode({
        'auto': 'auto',
        'models': ['auto', 'manual-model'],
        'tier': tier,
        'manualModelsAllowed': manual,
        'known': true,
      }),
      200,
    );

Future<void> openPicker(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.unfold_more).first);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 'account-a';
    OvidCloudService.appCheckTokenProvider = () async => 'attestation';
  });
  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.appCheckTokenProvider = null;
    OvidCloudService.httpClientFactoryForTest = null;
    OvidCloudService.forceRefreshIdTokenOverrideForTest = null;
    OvidCloudService.clockForTest = DateTime.now;
    AppState.resetTestInstance();
  });

  testWidgets(
    'failed mint stays visible and picker retry binds once with real catalog',
    (tester) async {
      var mints = 0;
      final reply = Completer<http.Response>();
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((request) async {
            if (request.url.path == '/mint') {
              expect(request.headers['X-Firebase-AppCheck'], 'attestation');
              return ++mints == 1
                  ? http.Response('secret-token internal error', 503)
                  : reply.future;
            }
            if (isModelAccess(request)) {
              // Firebase-authenticated, not the scoped key.
              expect(request.headers['Authorization'], 'Bearer account-a');
              return modelAccess();
            }
            expect(request.headers['Authorization'], 'Bearer scoped-key');
            return catalog();
          });
      await OvidCloudService.I.bindOvidCloud();
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await openPicker(tester);
      expect(find.text('Ovid Cloud'), findsOneWidget);
      expect(find.textContaining('503'), findsOneWidget);
      expect(find.textContaining('secret-token'), findsNothing);
      expect(find.textContaining('Ovid Cloud — add API keys'), findsNothing);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.descendant(
                of: find.byKey(const ValueKey('cloud-connection-retry')),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(mints, 2);
      reply.complete(mint());
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(OvidCloudService.I.connectionFor(AppState.I).error, isNull);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      expect(find.text('manual-model'), findsOneWidget);
      await tester.ensureVisible(find.text('manual-model'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('manual-model'));
      await tester.pumpAndSettle();
      expect(AppState.I.activeSession!.model, 'manual-model');
      await openPicker(tester);
      await tester.tap(find.text('Auto').first);
      await tester.pumpAndSettle();
      expect(AppState.I.activeSession!.model, 'auto');
      expect(mints, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'login resume retries a failed mint without auth notification floods',
    (tester) async {
      final service = GateService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountReady = true;
      service.initialization.complete();
      var mints = 0;
      var now = DateTime(2026, 10, 11, 12);
      OvidCloudService.clockForTest = () => now;
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((request) async {
            if (request.url.path == '/mint') {
              return ++mints == 1 ? http.Response('down', 503) : mint();
            }
            if (isModelAccess(request)) return modelAccess();
            return catalog();
          });
      await tester.pumpWidget(
        MaterialApp(
          home: LoginGate(service: service, child: const Text('Protected app')),
        ),
      );
      await tester.pumpAndSettle();
      expect(mints, 1);
      service.notifyListeners();
      service.notifyListeners();
      await tester.pumpAndSettle();
      expect(mints, 1);
      // A resume inside the backoff window does not hit the gateway.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(mints, 1);
      now = now.add(const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();
      expect(mints, 2);
      expect(OvidCloudService.I.connectionFor(AppState.I).error, isNull);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      expect(AppState.I.providerById('ovid-cloud')!.models, [
        'auto',
        'manual-model',
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(mints, 2);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );

  for (final response in [
    http.Response('private gateway details', 503),
    http.Response('not json: private gateway details', 200),
    http.Response('{"data":[{"id":123}]}', 200),
    http.Response('{"data":[]}', 200),
  ]) {
    testWidgets(
      'catalog failure ${response.statusCode}/${response.body} is visible and retry reuses key',
      (tester) async {
        var mints = 0;
        var models = 0;
        final pending = Completer<http.Response>();
        OvidCloudService.httpClientFactoryForTest = () =>
            MockClient((request) async {
              if (request.url.path == '/mint') {
                mints++;
                return mint();
              }
              if (isModelAccess(request)) return modelAccess();
              return ++models == 1 ? response : pending.future;
            });
        await tester.runAsync(() => OvidCloudService.I.ensureConnected());
        final app = AppState.I;
        expect(
          OvidCloudService.I.connectionFor(app).status,
          CloudConnectionStatus.failed,
        );
        expect(
          OvidCloudService.I.connectionFor(app).error,
          contains(response.body),
        );
        expect(app.providerById('ovid-cloud')!.models, ['auto']);
        await tester.pumpWidget(
          MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
        );
        await openPicker(tester);
        expect(
          find.text(OvidCloudService.I.connectionFor(app).error!),
          findsOneWidget,
        );
        // The server-side Auto alias stays usable; the catalog is marked
        // possibly stale instead of being hidden.
        expect(
          find.descendant(
            of: find.byType(ListTile),
            matching: find.text('Auto'),
          ),
          findsWidgets,
        );
        expect(
          find.byKey(const ValueKey('cloud-catalog-stale')),
          findsOneWidget,
        );
        await tester.tap(find.text('Retry'));
        await tester.runAsync(() async {});
        await tester.pump();
        final first = OvidCloudService.I.ensureConnected();
        final second = OvidCloudService.I.ensureConnected();
        expect(identical(first, second), isTrue);
        expect(models, 2);
        expect(mints, 1);
        pending.complete(catalog());
        await tester.runAsync(() async {});
        await tester.pumpAndSettle();
        expect(find.text('manual-model'), findsOneWidget);
        expect(
          OvidCloudService.I.connectionFor(app).status,
          CloudConnectionStatus.ready,
        );
        expect(mints, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final change in ['account', 'key', 'provider', 'base URL']) {
    test(
      'late catalog success and failure are fenced after $change changes',
      () async {
        for (final lateResponse in [
          catalog(),
          http.Response('private old failure', 503),
        ]) {
          OvidCloudService.idTokenOverrideForTest = () async => 'fresh-account';
          final entered = Completer<void>();
          final reply = Completer<http.Response>();
          final client = MockClient((request) async {
            if (request.url.path == '/mint') return mint();
            if (isModelAccess(request)) return modelAccess();
            entered.complete();
            return reply.future;
          });
          final app = AppState.I;
          final pending = OvidCloudService.I.ensureConnected(client: client);
          await entered.future;
          final provider = app.providerById('ovid-cloud')!;
          switch (change) {
            case 'account':
              OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
            case 'key':
              await app.updateProviderApiKey(provider, 'replacement-key');
            case 'provider':
              app.providers.remove(provider);
              app.providers.add(
                ProviderConfig(
                  id: 'ovid-cloud',
                  name: 'Ovid Cloud',
                  description: '',
                  baseUrl: 'https://example.test/v1',
                  apiKey: '',
                  isFree: true,
                  models: ['auto'],
                ),
              );
            case 'base URL':
              provider.baseUrl = 'https://replacement.test/v1';
          }
          expect(
            OvidCloudService.I.connectionFor(app).status,
            CloudConnectionStatus.idle,
          );
          reply.complete(lateResponse);
          expect((await pending).ok, isFalse);
          expect(
            OvidCloudService.I.connectionFor(app).status,
            CloudConnectionStatus.idle,
          );
          expect(
            app.providerById('ovid-cloud')!.models,
            isNot(contains('manual-model')),
          );
          client.close();
        }
      },
    );
  }

  test(
    'unavailable attestation is optional and mint statuses remain retryable',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('gateway unavailable', 503);
      });
      OvidCloudService.appCheckTokenProvider = () async =>
          throw StateError('private token');
      final failed = await OvidCloudService.I.ensureConnected(client: client);
      expect(failed.ok, isFalse);
      expect(failed.status, MintStatus.unavailable);
      expect(calls, greaterThan(0));
      client.close();
      OvidCloudService.appCheckTokenProvider = () async => 'attestation';
      for (final entry in {
        402: MintStatus.freeLimitReached,
        401: MintStatus.sessionExpired,
        403: MintStatus.deviceUnverified,
        503: MintStatus.unavailable,
      }.entries) {
        final client = MockClient(
          (_) async => http.Response('private token', entry.key),
        );
        await OvidCloudService.I.ensureConnected(client: client);
        final state = OvidCloudService.I.connectionFor(AppState.I);
        expect(state.mintStatus, entry.value);
        expect(state.error, isNot(contains('private')));
        client.close();
      }
    },
  );

  test(
    'queued recovery is busy and credential changes return a stale outcome',
    () async {
      final entered = Completer<void>();
      final upgradeReply = Completer<http.Response>();
      final client = MockClient((request) async {
        expect(request.url.path, '/upgrade');
        entered.complete();
        return upgradeReply.future;
      });
      final upgrade = OvidCloudService.I.upgrade('3x', client: client);
      await entered.future;
      final recovery = OvidCloudService.I.ensureConnected(client: client);
      expect(OvidCloudService.I.connectionFor(AppState.I).loading, isTrue);
      await AppState.I.updateProviderApiKey(
        AppState.I.providerById('ovid-cloud')!,
        'changed',
      );
      upgradeReply.complete(http.Response('down', 503));
      await upgrade;
      expect((await recovery).ok, isFalse);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.idle,
      );
      client.close();
    },
  );

  test(
    'new account recovery bypasses old flight and ignores its late error',
    () async {
      final entered = Completer<void>();
      final oldReply = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          if (request.headers['Authorization'] == 'Bearer account-a') {
            entered.complete();
            return oldReply.future;
          }
          return mint();
        }
        if (isModelAccess(request)) return modelAccess();
        return catalog();
      });
      final old = OvidCloudService.I.ensureConnected(client: client);
      await entered.future;
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      expect(
        (await OvidCloudService.I.ensureConnected(client: client)).ok,
        isTrue,
      );
      oldReply.complete(http.Response('old private error', 503));
      expect((await old).ok, isFalse);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      client.close();
    },
  );

  test(
    'catalog auth rejection retries mint rather than reusing a rejected key',
    () async {
      var mints = 0;
      var models = 0;
      final mintBodies = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          mintBodies.add(request.body);
          return ++mints == 1 ? mint() : mint('rotated-key');
        }
        if (isModelAccess(request)) return modelAccess();
        return ++models == 1 ? http.Response('private reason', 401) : catalog();
      });
      // A freshly minted key that the catalog rejects is rotated once in
      // the same flight; a second Retry is not needed.
      await OvidCloudService.I.ensureConnected(client: client);
      expect(mints, 2);
      expect(models, 2);
      // The re-mint names the rejected key by hash so the gateway rotates it.
      expect(mintBodies.first, isEmpty);
      expect(jsonDecode(mintBodies.last), {
        'reason': 'key_rejected',
        'key_id': sha256.convert(utf8.encode('scoped-key')).toString(),
      });
      expect(mintBodies.last, isNot(contains('scoped-key')));
      expect(AppState.I.providerById('ovid-cloud')!.apiKey, 'rotated-key');
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      client.close();
    },
  );

  test(
    'retry re-mints once when the bound key is rejected as catalog_unavailable',
    () async {
      var mints = 0;
      var models = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          return ++mints == 1 ? mint() : mint('rotated-key');
        }
        if (isModelAccess(request)) return modelAccess();
        return switch (++models) {
          1 => http.Response('down', 500),
          2 => http.Response('{"error":{"code":"catalog_unavailable"}}', 503),
          _ => catalog(),
        };
      });
      await OvidCloudService.I.ensureConnected(client: client);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.failed,
      );
      // A generic outage keeps the bound key: Retry re-fetches the catalog,
      // which now rejects the key, so the same Retry mints a fresh key.
      expect(
        (await OvidCloudService.I.ensureConnected(client: client)).ok,
        isTrue,
      );
      expect(mints, 2);
      expect(models, 3);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      client.close();
    },
  );

  test(
    'failed upgrade retains ready connection without an unnecessary recovery',
    () async {
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        return switch (request.url.path) {
          '/mint' => mint(),
          '/upgrade' => http.Response('down', 503),
          '/cloud/v1/models' => modelAccess(),
          _ => catalog(),
        };
      });
      await OvidCloudService.I.ensureConnected(client: client);
      expect(await OvidCloudService.I.upgrade('3x', client: client), isNull);
      expect(
        OvidCloudService.I.connectionFor(AppState.I).status,
        CloudConnectionStatus.ready,
      );
      await OvidCloudService.I.ensureConnected(client: client);
      expect(paths, ['/mint', '/v1/models', '/cloud/v1/models', '/upgrade']);
      client.close();
    },
  );

  test('changed base URL must rebind before sending a scoped key', () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      expect(request.url.host, isNot('replacement.test'));
      if (request.url.path == '/mint') return mint();
      if (isModelAccess(request)) return modelAccess();
      return catalog();
    });
    await OvidCloudService.I.ensureConnected(client: client);
    AppState.I.providerById('ovid-cloud')!.baseUrl =
        'https://replacement.test/v1';
    await OvidCloudService.I.ensureConnected(client: client);
    expect(paths, [
      '/mint',
      '/v1/models',
      '/cloud/v1/models',
      '/mint',
      '/v1/models',
      '/cloud/v1/models',
    ]);
    client.close();
  });

  test(
    'mint and catalog retries share one flight through credential binding',
    () async {
      var mints = 0;
      final modelsEntered = Completer<void>();
      final reply = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.path == '/mint') {
          mints++;
          return mint();
        }
        if (isModelAccess(request)) return modelAccess();
        modelsEntered.complete();
        return reply.future;
      });
      final first = OvidCloudService.I.ensureConnected(client: client);
      expect(
        identical(first, OvidCloudService.I.ensureConnected(client: client)),
        isTrue,
      );
      await modelsEntered.future;
      expect(
        identical(first, OvidCloudService.I.ensureConnected(client: client)),
        isTrue,
      );
      reply.complete(catalog());
      await first;
      expect(mints, 1);
      client.close();
    },
  );
}
