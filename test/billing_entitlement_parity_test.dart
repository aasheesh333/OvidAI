import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/billing_products.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/entitlement_client.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/revenuecat_billing.dart';

class _Store implements RevenueCatPlatform {
  _Store({this.offered = const []});

  final List<RevenueCatPackage> offered;
  final RevenueCatResult restoreResult = const RevenueCatResult(
    ok: true,
    tier: '3x',
  );

  int configureCalls = 0;
  int packageCalls = 0;
  int purchaseCalls = 0;
  int restoreCalls = 0;
  int customerInfoCalls = 0;

  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {
    configureCalls++;
  }

  @override
  Future<List<RevenueCatPackage>> packages() async {
    packageCalls++;
    return offered;
  }

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async {
    purchaseCalls++;
    return const RevenueCatResult(ok: true, tier: '3x');
  }

  @override
  Future<RevenueCatResult> restore() async {
    restoreCalls++;
    return restoreResult;
  }

  @override
  Future<RevenueCatResult> customerInfo() async {
    customerInfoCalls++;
    return const RevenueCatResult(ok: false);
  }
}

RevenueCatPackage _package(String productId) => RevenueCatPackage(
  identifier: productId,
  productId: productId,
  title: productId,
  priceString: r'$1',
);

RevenueCatBilling _billing(
  _Store store, {
  RevenueCatConfig config = const RevenueCatConfig(apiKey: 'goog_test'),
  required Future<BillingEntitlement?> Function() serverEntitlement,
  void Function(String tier)? applyTier,
}) => RevenueCatBilling(
  platform: store,
  uid: () => 'u1',
  config: config,
  serverConfirmation: true,
  playActive: () => false,
  applyTier: applyTier,
  serverEntitlement: serverEntitlement,
);

BillingEntitlement _active({String tier = '7x', String? productId}) =>
    BillingEntitlement.fromJson({
      'tier': tier,
      'productId':
          productId ??
          switch (tier) {
            '3x' => 'ovid_plus_yearly',
            '15x' => 'ovid_max_yearly',
            _ => 'ovid_pro_yearly',
          },
      'purchaseState': 'active',
      'expiresAt': '2099-11-20T00:00:00.000Z',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    Distribution.billingDemoOverrideForTest = null;
    Distribution.productionOverrideForTest = null;
  });

  test('canonical monthly and yearly product pairs are exact', () {
    expect(kOvidPlayProductIds, {
      ('3x', OvidBillingPeriod.monthly): 'ovid_plus_monthly',
      ('3x', OvidBillingPeriod.yearly): 'ovid_plus_yearly',
      ('7x', OvidBillingPeriod.monthly): 'ovid_pro_monthly',
      ('7x', OvidBillingPeriod.yearly): 'ovid_pro_yearly',
      ('15x', OvidBillingPeriod.monthly): 'ovid_max_monthly',
      ('15x', OvidBillingPeriod.yearly): 'ovid_max_yearly',
    });
  });

  test('entitlement exposes tier, period, product, state and expiry', () async {
    final requests = <http.Request>[];
    final client = EntitlementClient(
      rest: CloudRestClient(
        restBase: 'https://cloud.test',
        headers: CloudHeaders.forTest(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'entitlement': {
                'tier': '7x',
                'period': 'yearly',
                'productId': 'ovid_pro_yearly',
                'purchaseState': 'active',
                'expiresAt': '2099-11-20T00:00:00.000Z',
              },
            }),
            200,
          );
        }),
      ),
    );

    final entitlement = await client.current();
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path, '/billing/entitlement');
    expect(entitlement?.tier, '7x');
    expect(entitlement?.period, OvidBillingPeriod.yearly);
    expect(entitlement?.productId, 'ovid_pro_yearly');
    expect(entitlement?.purchaseState, 'active');
    expect(entitlement?.expiresAt, DateTime.parse('2099-11-20T00:00:00.000Z'));
    expect(entitlement?.isActiveAt(DateTime.utc(2026, 10, 24)), isTrue);
  });

  test(
    'malformed entitlement is unknown, never a confirmed free account',
    () async {
      final rest = CloudRestClient(
        restBase: 'https://cloud.test',
        headers: CloudHeaders.forTest(),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'totals': {'runs': 9, 'inputTokens': 100},
            }),
            200,
          ),
        ),
      );
      final client = EntitlementClient(rest: rest);
      await expectLater(client.current(), throwsFormatException);

      final applied = <String>[];
      final billing = _billing(
        _Store(),
        applyTier: applied.add,
        serverEntitlement: client.current,
      );
      await expectLater(
        billing.refreshServerEntitlement(),
        throwsFormatException,
      );
      expect(billing.serverEntitlementKnown, isFalse);
      expect(applied, isEmpty);
    },
  );

  test('recognized malformed entitlement fields never become authority', () {
    final active = <String, Object?>{
      'tier': '7x',
      'period': 'yearly',
      'productId': 'ovid_pro_yearly',
      'purchaseState': 'active',
      'expiresAt': '2099-11-20T00:00:00.000Z',
      'autoRenewing': true,
    };
    final malformed = <String, Map<String, Object?>>{
      'tier': <String, Object?>{...active, 'tier': 7},
      'unknown tier': <String, Object?>{...active, 'tier': 'future'},
      'product type': <String, Object?>{...active, 'productId': 7},
      'unknown product': <String, Object?>{
        ...active,
        'productId': 'ovid_unknown_yearly',
      },
      'tier product mismatch': <String, Object?>{
        ...active,
        'productId': 'ovid_max_yearly',
      },
      'period type': <String, Object?>{...active, 'period': 12},
      'period product mismatch': <String, Object?>{
        ...active,
        'period': 'monthly',
      },
      'purchase state': <String, Object?>{
        ...active,
        'purchaseState': 'sometimes',
      },
      'expiry type': <String, Object?>{...active, 'expiresAt': 0},
      'expiry malformed': <String, Object?>{
        ...active,
        'expiresAt': 'eventually',
      },
      'active without expiry': <String, Object?>{...active}
        ..remove('expiresAt'),
      'auto renewing type': <String, Object?>{...active, 'autoRenewing': 'yes'},
    };

    for (final entry in malformed.entries) {
      expect(
        () => BillingEntitlement.fromJson(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }

    const missingExpiry = BillingEntitlement(
      tier: '7x',
      period: OvidBillingPeriod.yearly,
      productId: 'ovid_pro_yearly',
      purchaseState: 'active',
      expiresAt: null,
    );
    expect(missingExpiry.isActiveAt(DateTime.utc(2026, 10, 24)), isFalse);
    expect(
      billingManagementUri(missingExpiry, now: DateTime.utc(2026, 10, 24)),
      isNull,
    );
  });

  test('expiry and refund revoke access and management deep links', () {
    final expired = BillingEntitlement.fromJson({
      'tier': '7x',
      'productId': 'ovid_pro_monthly',
      'purchaseState': 'active',
      'expiresAt': '2026-10-23T00:00:00.000Z',
    });
    final refunded = BillingEntitlement.fromJson({
      'tier': '7x',
      'productId': 'ovid_pro_monthly',
      'purchaseState': 'refunded',
      'expiresAt': '2099-11-20T00:00:00.000Z',
    });
    final now = DateTime.utc(2026, 10, 24);

    expect(expired.isActiveAt(now), isFalse);
    expect(refunded.isActiveAt(now), isFalse);
    expect(billingManagementUri(expired, now: now), isNull);
    expect(billingManagementUri(refunded, now: now), isNull);
    expect(
      billingManagementUri(_active(), now: now)?.toString(),
      'https://play.google.com/store/account/subscriptions?sku=ovid_pro_yearly&package=com.dhanuk.ovidai',
    );
  });

  test('fresh entitlement authority outranks a stale usage projection', () {
    final active = _active(tier: '15x', productId: 'ovid_max_yearly');
    final refunded = BillingEntitlement.fromJson({
      'tier': '7x',
      'purchaseState': 'refunded',
      'productId': 'ovid_pro_monthly',
    });

    expect(
      authoritativeServerTier(
        entitlementKnown: true,
        entitlement: active,
        usageTier: '7x',
      ),
      '15x',
    );
    expect(
      authoritativeServerTier(
        entitlementKnown: true,
        entitlement: refunded,
        usageTier: '7x',
      ),
      'free',
    );
    expect(
      authoritativeServerTier(
        entitlementKnown: false,
        entitlement: null,
        usageTier: '7x',
      ),
      '7x',
    );
  });

  test(
    'restore rereads server authority instead of trusting the store tier',
    () async {
      final store = _Store();
      final applied = <String>[];
      var serverReads = 0;
      final billing = _billing(
        store,
        applyTier: applied.add,
        serverEntitlement: () async {
          serverReads++;
          return _active(tier: '15x', productId: 'ovid_max_yearly');
        },
      );

      final outcome = await billing.restore();

      expect(store.restoreCalls, 1);
      expect(serverReads, 1);
      expect(outcome.tier, '15x');
      expect(outcome.result, UpgradeResult.ok);
      expect(applied, ['15x']);
    },
  );

  test(
    'restore applies a server refund instead of restoring a stale store plan',
    () async {
      final store = _Store();
      final applied = <String>[];
      final billing = _billing(
        store,
        applyTier: applied.add,
        serverEntitlement: () async => BillingEntitlement.fromJson({
          'tier': '7x',
          'productId': 'ovid_pro_monthly',
          'purchaseState': 'refunded',
          'expiresAt': '2099-11-20T00:00:00.000Z',
        }),
      );

      final outcome = await billing.restore();

      expect(outcome.result, UpgradeResult.nothingToRestore);
      expect(applied, ['free']);
    },
  );

  test('account switch rereads the new account server entitlement', () async {
    final store = _Store();
    final applied = <String>[];
    var uid = 'u1';
    var serverReads = 0;
    final billing = RevenueCatBilling(
      platform: store,
      uid: () => uid,
      config: const RevenueCatConfig(apiKey: 'goog_test'),
      serverConfirmation: true,
      playActive: () => false,
      applyTier: applied.add,
      serverEntitlement: () async {
        serverReads++;
        return _active(tier: uid == 'u2' ? '15x' : '3x');
      },
    );

    await billing.configure(uid: 'u1');
    expect(serverReads, 0);
    uid = 'u2';
    await billing.configure();

    expect(serverReads, 1);
    expect(store.configureCalls, 2);
    expect(applied, ['15x']);
  });

  test(
    'restarting billing after account switch rereads server authority',
    () async {
      final store = _Store();
      final applied = <String>[];
      var uid = 'u1';
      var serverReads = 0;
      final billing = RevenueCatBilling(
        platform: store,
        uid: () => uid,
        config: const RevenueCatConfig(apiKey: 'goog_test'),
        serverConfirmation: true,
        playActive: () => false,
        applyTier: applied.add,
        serverEntitlement: () async {
          serverReads++;
          return _active(tier: uid == 'u2' ? '15x' : '3x');
        },
      );

      billing.start();
      await Future<void>.delayed(Duration.zero);
      uid = 'u2';
      billing.start();
      await Future<void>.delayed(Duration.zero);

      expect(serverReads, greaterThan(1));
      expect(applied.last, '15x');
    },
  );

  test(
    'a late old-account entitlement cannot unlock the new account',
    () async {
      final store = _Store();
      final applied = <String>[];
      var uid = 'u1';
      final answer = Completer<BillingEntitlement?>();
      final billing = RevenueCatBilling(
        platform: store,
        uid: () => uid,
        config: const RevenueCatConfig(apiKey: 'goog_test'),
        serverConfirmation: true,
        playActive: () => false,
        applyTier: applied.add,
        serverEntitlement: () => answer.future,
      );
      await billing.configure(uid: 'u1');

      final pending = billing.refreshServerEntitlement();
      uid = 'u2';
      answer.complete(_active(tier: '3x'));

      await expectLater(pending, throwsStateError);
      expect(applied, isEmpty);
      expect(billing.serverEntitlementKnown, isFalse);
    },
  );

  test('same UID latest entitlement read wins out of order', () async {
    final older = Completer<BillingEntitlement?>();
    final newer = Completer<BillingEntitlement?>();
    final applied = <String>[];
    var reads = 0;
    final billing = _billing(
      _Store(),
      applyTier: applied.add,
      serverEntitlement: () {
        reads++;
        return (reads == 1 ? older : newer).future;
      },
    );

    final oldRead = billing.refreshServerEntitlement();
    final newRead = billing.refreshServerEntitlement();
    newer.complete(null);
    expect(await newRead, isNull);
    expect(applied, ['free']);

    older.complete(_active(tier: '7x'));
    await expectLater(oldRead, throwsStateError);
    expect(applied, ['free']);
    expect(billing.serverEntitlement, isNull);
    expect(billing.serverEntitlementKnown, isTrue);
  });

  test('superseded restore cannot fall back to a stale store tier', () async {
    final older = Completer<BillingEntitlement?>();
    final newer = Completer<BillingEntitlement?>();
    var reads = 0;
    final billing = _billing(
      _Store(),
      serverEntitlement: () {
        reads++;
        return (reads == 1 ? older : newer).future;
      },
    );

    final oldRestore = billing.restore();
    final newRestore = billing.restore();
    newer.complete(null);
    expect((await newRestore).result, UpgradeResult.nothingToRestore);

    older.complete(_active(tier: '15x', productId: 'ovid_max_yearly'));
    final staleOutcome = await oldRestore;
    expect(staleOutcome.ok, isFalse);
    expect(staleOutcome.tier, isNull);
  });

  test('superseded entitlement failure cannot use a store fallback', () async {
    final older = Completer<BillingEntitlement?>();
    final newer = Completer<BillingEntitlement?>();
    var reads = 0;
    final billing = _billing(
      _Store(),
      serverEntitlement: () {
        reads++;
        return (reads == 1 ? older : newer).future;
      },
    );

    final oldRestore = billing.restore();
    final newRestore = billing.restore();
    newer.complete(null);
    expect((await newRestore).result, UpgradeResult.nothingToRestore);

    older.completeError(StateError('older malformed response'));
    final staleOutcome = await oldRestore;
    expect(staleOutcome.ok, isFalse);
    expect(staleOutcome.tier, isNull);
  });

  test('missing yearly is unavailable and never purchases monthly', () async {
    final store = _Store(offered: [_package('ovid_plus_monthly')]);
    final billing = _billing(
      store,
      serverEntitlement: () async => throw StateError('not read by purchase'),
    );

    final outcome = await billing.buy('3x', period: OvidBillingPeriod.yearly);

    expect(outcome.result, UpgradeResult.notAvailable);
    expect(store.purchaseCalls, 0);
  });

  test(
    'unconfigured purchase and restore make no store or server calls',
    () async {
      final store = _Store();
      var serverReads = 0;
      final billing = _billing(
        store,
        config: const RevenueCatConfig(),
        serverEntitlement: () async {
          serverReads++;
          return null;
        },
      );

      expect((await billing.buy('3x')).result, UpgradeResult.notAvailable);
      expect((await billing.restore()).result, UpgradeResult.notAvailable);
      expect(store.configureCalls, 0);
      expect(store.packageCalls, 0);
      expect(store.purchaseCalls, 0);
      expect(store.restoreCalls, 0);
      expect(serverReads, 0);
    },
  );

  test('release checkout has no Web or demo grant path', () async {
    Distribution.productionOverrideForTest = true;
    Distribution.billingDemoOverrideForTest = true;
    final config = resolveRevenueCatConfig(
      releaseMode: true,
      testStoreRequested: true,
      googleKey: '',
      testStoreKey: 'test_key',
    );

    expect(config.available, isFalse);
    expect(config.testStore, isFalse);
    expect(demoGrantAllowed(releaseMode: true, testStore: true), isFalse);

    final store = _Store();
    final billing = _billing(
      store,
      config: const RevenueCatConfig(),
      serverEntitlement: () async => null,
    );
    final outcome = await billing.buy('3x');
    expect(outcome.ok, isFalse);
    expect(billing.lastPurchaseWasDemo, isFalse);
    expect(store.purchaseCalls, 0);
    expect(
      resolveBillingRoute(
        playLoaded: true,
        playAvailable: false,
        revenueCat: billing,
      ),
      isNot(BillingRoute.demo),
    );
  });
}
