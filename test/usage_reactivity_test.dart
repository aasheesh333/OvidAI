import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _rowSequence = 0;

UsageAttempt row({String provider = 'ovid-cloud', int tokens = 20}) {
  final id = 'reactivity-row-${_rowSequence++}';
  final startedAt = DateTime.now().toUtc();
  return UsageAttempt(
    attemptId: id,
    requestId: 'request-$id',
    revision: 1,
    sourceDevice: 'test-device',
    provider: provider,
    requestedModel: 'model',
    reportedModel: 'model',
    purpose: 'chat',
    startedAt: startedAt,
    completedAt: startedAt,
    elapsed: const Duration(seconds: 1),
    dispatchStage: UsageDispatchStage.completed,
    outcome: UsageOutcome.succeeded,
    inputTokens: UsageTokenCount.reported(tokens),
    outputTokens: UsageTokenCount.reported(10),
    totalTokens: UsageTokenCount.reported(tokens + 10),
  );
}

Future<void> addRowInTest(WidgetTester tester, {
  String provider = 'ovid-cloud',
  int tokens = 20,
}) async {
  await tester.runAsync(
    () => AppState.I.recordUsageAttempt(row(provider: provider, tokens: tokens)),
  );
}

http.Response usage(double remaining, {String tier = 'free'}) => http.Response(
  jsonEncode({
    'tier': tier,
    'is_paid': tier != 'free',
    'remaining_pct': remaining,
    'models': [],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory usageRoot;
  setUp(() async {
    _rowSequence = 0;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    usageRoot = await Directory.systemTemp.createTemp('usage-reactivity-');
    AppState.resetTestInstance();
    AppState.createForTest(usageRoot: usageRoot);
    await AppState.I.prepareUsageAttempts(
      owner: AppState.I.sessionAccountToken,
    );
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'account-a';
  });
  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.appCheckTokenProvider = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  for (final endpoint in ['mint', 'usage', 'upgrade']) {
    test('late $endpoint response cannot apply to another account', () async {
      final entered = Completer<void>();
      final reply = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.path == '/$endpoint') {
          entered.complete();
          return reply.future;
        }
        return http.Response('{"data":[{"id":"old-model"}]}', 200);
      });
      final service = OvidCloudService.I;
      final Future<Object?> pending = switch (endpoint) {
        'mint' => service.bindOvidCloud(client: client),
        'usage' => service.fetchUsage(client: client),
        _ => service.upgrade('7x', client: client),
      };
      await entered.future;
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      final provider = AppState.I.providerById('ovid-cloud')!;
      await AppState.I.updateProviderApiKey(provider, 'key-b');
      AppState.I.setOvidCloudTier('3x');
      reply.complete(
        http.Response(
          jsonEncode({
            'key': 'key-a',
            'tier': '7x',
            'ok': true,
            'remaining_pct': 0.12,
            'base_url': 'https://example.test/v1/',
          }),
          200,
        ),
      );
      final result = await pending;
      if (result is MintOutcome) {
        expect(result.ok, isFalse);
      } else {
        expect(result, isNull);
      }
      expect(provider.cleanApiKey, 'key-b');
      expect(AppState.I.ovidCloudTier, '3x');
      client.close();
    });
  }

  test('missing App Check is optional when the gateway does not require it', () async {
    OvidCloudService.appCheckTokenProvider = () async => null;
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      return http.Response('{"key":"unverified"}', 200);
    });
    final result = await OvidCloudService.I.bindOvidCloud(client: client);
    expect(result.ok, isTrue);
    expect(calls, greaterThan(0));
    client.close();
  });

  for (final stage in ['id token', 'App Check']) {
    test(
      'account change during $stage cannot send mixed credentials',
      () async {
        final entered = Completer<void>();
        final credential = Completer<String?>();
        if (stage == 'id token') {
          OvidCloudService.idTokenOverrideForTest = () {
            entered.complete();
            return credential.future;
          };
        } else {
          OvidCloudService.appCheckTokenProvider = () {
            entered.complete();
            return credential.future;
          };
        }
        var requests = 0;
        final client = MockClient((_) async {
          requests++;
          return usage(0.9);
        });
        final pending = OvidCloudService.I.fetchUsage(client: client);
        await entered.future;
        OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
        credential.complete('old-credential');
        expect(await pending, isNull);
        expect(requests, 0);
        client.close();
      },
    );
  }

  test('attestation reaches all authenticated cloud endpoints', () async {
    OvidCloudService.appCheckTokenProvider = () async => 'verified-app';
    final paths = <String>[];
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/models')) {
        expect(request.headers['X-Firebase-AppCheck'], 'verified-app');
        paths.add(request.url.path);
      }
      return switch (request.url.path) {
        '/mint' => http.Response('{"key":"key-a","tier":"free"}', 200),
        '/upgrade' => http.Response('{"ok":true,"tier":"3x"}', 200),
        '/usage' => usage(0.7),
        _ => http.Response('{"data":[]}', 200),
      };
    });
    expect((await OvidCloudService.I.bindOvidCloud(client: client)).ok, isTrue);
    expect(await OvidCloudService.I.fetchUsage(client: client), isNotNull);
    expect(await OvidCloudService.I.upgrade('3x', client: client), '3x');
    expect(
      (await OvidCloudService.I.imageHeaders())['X-Firebase-AppCheck'],
      'verified-app',
    );
    expect(paths, ['/mint', '/usage', '/upgrade']);
    client.close();
  });

  test('upgrade never fetches models with an unowned persisted key', () async {
    await AppState.I.updateProviderApiKey(
      AppState.I.providerById('ovid-cloud')!,
      'previous-account-key',
    );
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response('{"ok":true,"tier":"3x"}', 200);
    });
    expect(await OvidCloudService.I.upgrade('3x', client: client), '3x');
    expect(paths, ['/upgrade']);
    client.close();
  });

  test(
    'same-account return does not revive an older session response',
    () async {
      final accountA = OvidCloudService.idTokenOverrideForTest;
      final entered = Completer<void>();
      final reply = Completer<http.Response>();
      final client = MockClient((_) async {
        entered.complete();
        return reply.future;
      });
      final pending = OvidCloudService.I.fetchUsage(client: client);
      await entered.future;
      OvidCloudService.idTokenOverrideForTest = () async => null;
      OvidCloudService.idTokenOverrideForTest = accountA;
      reply.complete(usage(0.9));
      expect(await pending, isNull);
      client.close();
    },
  );

  for (final success in [false, true]) {
    test(
      'delayed login mint binds once before ${success ? 'successful' : 'failed'} upgrade',
      () async {
        final entered = Completer<void>();
        final mint = Completer<http.Response>();
        final app = AppState.I;
        final provider = app.providerById('ovid-cloud')!;
        final paths = <String>[];
        var keyBindings = 0;
        var lastKey = provider.cleanApiKey;
        void observeKey() {
          if (lastKey != provider.cleanApiKey) {
            keyBindings++;
            lastKey = provider.cleanApiKey;
          }
        }

        app.addListener(observeKey);
        addTearDown(() => app.removeListener(observeKey));
        final client = MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path == '/mint') {
            entered.complete();
            return mint.future;
          }
          if (request.url.path == '/upgrade') {
            expect(provider.cleanApiKey, 'login-key');
            return http.Response(
              '{"ok":$success,"tier":"7x"}',
              success ? 200 : 503,
            );
          }
          expect(request.headers['Authorization'], 'Bearer login-key');
          return http.Response('{"data":[]}', 200);
        });
        addTearDown(client.close);
        final pending = OvidCloudService.I.bindOvidCloud(client: client);
        await entered.future;
        final upgrade = OvidCloudService.I.upgrade('7x', client: client);
        mint.complete(http.Response('{"key":"login-key","tier":"free"}', 200));
        expect((await pending).ok, isTrue);
        expect(await upgrade, success ? '7x' : null);
        expect(provider.cleanApiKey, 'login-key');
        expect(keyBindings, 1);
        expect(paths.where((p) => p == '/mint').length, 1);
        expect(paths.where((p) => p == '/upgrade').length, 1);
        expect(app.ovidCloudTier, success ? '7x' : 'free');
        expect(OvidCloudService.I.confirmedTier, success ? '7x' : 'free');
        expect(
          (await OvidCloudService.I.imageHeaders())['X-Ovid-Key'],
          'login-key',
        );
      },
    );
  }

  test(
    'new account mint bypasses old queue and old queued upgrade never runs',
    () async {
      final entered = Completer<void>();
      final oldMint = Completer<http.Response>();
      final paths = <String>[];
      final client = MockClient((request) async {
        final auth = request.headers['Authorization'];
        paths.add('$auth ${request.url.path}');
        if (request.url.path == '/mint') {
          if (auth == 'Bearer account-a') {
            entered.complete();
            return oldMint.future;
          }
          return http.Response('{"key":"key-b","tier":"3x"}', 200);
        }
        if (request.url.path == '/upgrade') {
          return http.Response('{"ok":true,"tier":"7x"}', 200);
        }
        return http.Response('{"data":[]}', 200);
      });
      addTearDown(client.close);
      final pending = OvidCloudService.I.bindOvidCloud(client: client);
      await entered.future;
      final upgrade = OvidCloudService.I.upgrade('7x', client: client);
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      final newMint = await OvidCloudService.I
          .bindOvidCloud(client: client)
          .timeout(const Duration(seconds: 2));
      expect(newMint.ok, isTrue);
      oldMint.complete(http.Response('{"key":"key-a","tier":"free"}', 200));
      expect((await pending).ok, isFalse);
      expect(await upgrade, isNull);
      expect(paths.where((p) => p.endsWith('/upgrade')), isEmpty);
      expect(AppState.I.providerById('ovid-cloud')!.cleanApiKey, 'key-b');
      expect(AppState.I.ovidCloudTier, '3x');
    },
  );

  test(
    'failed mint releases the mutation queue for a retry and upgrade',
    () async {
      final entered = Completer<void>();
      final firstReply = Completer<http.Response>();
      var mints = 0;
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/mint') {
          if (++mints == 1) {
            entered.complete();
            return firstReply.future;
          }
          return http.Response('{"key":"retry-key","tier":"free"}', 200);
        }
        if (request.url.path == '/upgrade') {
          return http.Response('{"ok":true,"tier":"3x"}', 200);
        }
        return http.Response('{"data":[]}', 200);
      });
      addTearDown(client.close);
      final failed = OvidCloudService.I.bindOvidCloud(client: client);
      await entered.future;
      final retry = OvidCloudService.I.bindOvidCloud(client: client);
      final upgrade = OvidCloudService.I.upgrade('3x', client: client);
      firstReply.complete(http.Response('unavailable', 503));
      expect((await failed).ok, isFalse);
      expect((await retry.timeout(const Duration(seconds: 2))).ok, isTrue);
      expect(await upgrade.timeout(const Duration(seconds: 2)), '3x');
      expect(paths.where((p) => !p.endsWith('/models')), [
        '/mint',
        '/mint',
        '/upgrade',
      ]);
      expect(AppState.I.providerById('ovid-cloud')!.cleanApiKey, 'retry-key');
      expect(AppState.I.ovidCloudTier, '3x');
    },
  );

  test(
    'image headers cannot combine a previous account key with the new token',
    () async {
      final client = MockClient(
        (request) async => request.url.path == '/mint'
            ? http.Response('{"key":"key-a","tier":"7x"}', 200)
            : http.Response('{"data":[]}', 200),
      );
      expect(
        (await OvidCloudService.I.bindOvidCloud(client: client)).ok,
        isTrue,
      );
      expect((await OvidCloudService.I.imageHeaders())['X-Ovid-Key'], 'key-a');
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      expect(await OvidCloudService.I.imageHeaders(), isEmpty);
      client.close();
    },
  );

  testWidgets(
    'unscoped persisted plan is not presented as the new account plan',
    (tester) async {
      AppState.I.setOvidCloudTier('15x');
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((_) async => http.Response('down', 503));
      await tester.pumpWidget(const MaterialApp(home: BillingScreen()));
      await tester.pumpAndSettle();
      expect(find.text('MAX'), findsNothing);
      expect(find.text('Plan unavailable'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('both mounted screens retain server allowance after local attempts', (
    tester,
  ) async {
    var remaining = 0.8;
    var calls = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      calls++;
      return usage(remaining);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Row(
          children: [
            Expanded(child: UsageScreen()),
            Expanded(child: BillingScreen()),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('80% remaining'), findsNWidgets(2));
    expect(calls, 1);
    remaining = 0.6;
    for (var i = 0; i < 20; i++) {
      AppState.I
          .refresh(); // Streaming/UI notifications are not usage receipts.
    }
    await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    await addRowInTest(tester);
    await addRowInTest(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    // Local approved-attempt rows do not invalidate the server allowance.
    expect(find.text('80% remaining'), findsNWidgets(2));
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'open provider detail recomputes measured request and token totals',
    (tester) async {
      await addRowInTest(tester, provider: 'custom');
      await tester.pumpWidget(
        MaterialApp(
          home: ProviderUsageScreen(
            provider: ProviderUsage(
              providerId: 'custom',
              providerName: 'custom',
              tier: 'BYOK',
              icon: Icons.cloud,
              color: Colors.blue,
              requests: 1,
              tokensIn: 20,
              tokensOut: 10,
              models: [
                UsageModelUsage('model')
                  ..requests = 1
                  ..measuredTotal = 30
                  ..measuredTotalKnown = true,
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 requests'), findsOneWidget);
      await addRowInTest(tester, provider: 'custom', tokens: 40);
      await tester.pumpAndSettle();
      expect(find.text('2 requests'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);
      AppState.I.usageLog.clear();
      AppState.I.refresh();
      await tester.pumpAndSettle();
      // Clearing the legacy compatibility list does not clear the durable
      // approved-attempt journal.
      expect(find.text('2 requests'), findsOneWidget);
    },
  );

  testWidgets(
    'in-flight explicit refreshes coalesce and failed refresh stays visibly stale',
    (tester) async {
      var calls = 0;
      final delayed = Completer<http.Response>();
      OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
        calls++;
        if (calls == 1) return usage(0.8);
        if (calls == 2) return delayed.future;
        return http.Response('down', 503);
      });
      await tester.pumpWidget(const MaterialApp(home: BillingScreen()));
      await tester.pumpAndSettle();
      final store = CloudUsageStore.acquire(AppState.I);
      store.release();
      store.refresh();
      await tester.pump();
      await addRowInTest(tester);
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 30; i++) {
        await addRowInTest(tester);
        store.refresh();
      }
      await tester.pump(const Duration(seconds: 3));
      expect(calls, 2);
      delayed.complete(usage(0.7));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.text('70% remaining'), findsOneWidget);
      expect(find.textContaining('may be out of date'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 3);
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((_) async => usage(0.5));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('50% remaining'), findsOneWidget);
      expect(find.textContaining('may be out of date'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'account switch clears both screens and ignores a late old snapshot',
    (tester) async {
      final oldReply = Completer<http.Response>();
      var calls = 0;
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((request) async {
            calls++;
            if (request.headers['Authorization'] == 'Bearer account-a') {
              return oldReply.future;
            }
            return usage(0.4);
          });
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              Expanded(child: UsageScreen()),
              Expanded(child: BillingScreen()),
            ],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, 1);
      OvidCloudService.idTokenOverrideForTest = () async => 'account-b';
      AppState.I.refresh();
      await tester.pumpAndSettle();
      expect(find.text('40% remaining'), findsNWidgets(2));
      oldReply.complete(usage(0.9, tier: '15x'));
      await tester.pumpAndSettle();
      expect(find.text('90% remaining'), findsNothing);
      expect(find.text('40% remaining'), findsNWidgets(2));
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('resume refreshes mounted allowance after cooldown', (
    tester,
  ) async {
    var remaining = 0.8;
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => usage(remaining));
    await tester.pumpWidget(const MaterialApp(home: UsageScreen()));
    await tester.pumpAndSettle();
    remaining = 0.3;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('30% remaining'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('late models cannot publish under a replaced key', () async {
    final entered = Completer<void>();
    final reply = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path == '/mint') {
        return http.Response(
          '{"key":"key-a","tier":"7x","base_url":"https://example.test/v1/"}',
          200,
        );
      }
      expect(request.headers['Authorization'], 'Bearer key-a');
      entered.complete();
      return reply.future;
    });
    final pending = OvidCloudService.I.bindOvidCloud(client: client);
    await entered.future;
    final provider = AppState.I.providerById('ovid-cloud')!;
    await AppState.I.updateProviderApiKey(provider, 'key-b');
    reply.complete(http.Response('{"data":[{"id":"old-model"}]}', 200));
    expect((await pending).ok, isFalse);
    expect(provider.models, isNot(contains('old-model')));
    expect(provider.cleanApiKey, 'key-b');
    client.close();
  });

  testWidgets(
    'upgrade invalidates a pending old-plan response for every consumer',
    (tester) async {
      final old = Completer<http.Response>();
      var calls = 0;
      var tier = 'free';
      OvidCloudService.httpClientFactoryForTest = () =>
          MockClient((request) async {
            if (request.url.path == '/usage') {
              calls++;
              if (calls == 2) return old.future;
              return usage(tier == 'free' ? 0.2 : 0.9, tier: tier);
            }
            if (request.url.path == '/upgrade') {
              tier = '3x';
              return http.Response('{"ok":true,"tier":"3x"}', 200);
            }
            return http.Response('{"data":[]}', 200);
          });
      await tester.pumpWidget(
        const MaterialApp(
          home: Row(
            children: [
              Expanded(child: UsageScreen()),
              Expanded(child: BillingScreen()),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final store = CloudUsageStore.acquire(AppState.I);
      store.release();
      store.refresh();
      await tester.pump();
      await addRowInTest(tester);
      await tester.pump(const Duration(seconds: 3));
      final upgrade = OvidCloudService.I.upgrade('3x');
      await tester.pumpAndSettle();
      expect(await upgrade, '3x');
      expect(find.text('90% remaining'), findsNWidgets(2));
      old.complete(usage(0.1));
      await tester.pumpAndSettle();
      expect(find.text('90% remaining'), findsNWidgets(2));
      expect(find.text('10% remaining'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('store releases pending timers when last consumer leaves', (
    tester,
  ) async {
    var calls = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      calls++;
      return usage(0.5);
    });
    final store = CloudUsageStore.acquire(AppState.I);
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, 1);
    await addRowInTest(tester);
    store.release();
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
  });

  testWidgets('local summary includes all retained provider-reported attempts', (
    tester,
  ) async {
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => usage(0.5));
    await addRowInTest(tester, tokens: 990);
    await addRowInTest(tester, provider: 'custom', tokens: 20);
    await tester.pumpWidget(const MaterialApp(home: UsageScreen()));
    await tester.pumpAndSettle();
    expect(find.text('1K in · 20 out'), findsOneWidget);
    expect(find.text('1 requests · 20 in · 10 out'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
