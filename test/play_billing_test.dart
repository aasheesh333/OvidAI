import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake Google Play store: the test drives purchase updates by hand.
class FakeBillingPlatform implements BillingPlatform {
  FakeBillingPlatform({this.storeAvailable = true});
  final bool storeAvailable;
  final controller = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <PurchaseDetails>[];
  final bought = <({String product, String accountId, String? replacing})>[];
  int restores = 0;
  List<PurchaseDetails> owned = [];

  @override
  Future<bool> isAvailable() async => storeAvailable;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => controller.stream;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      ProductDetailsResponse(
        productDetails: [
          for (final id in ids)
            ProductDetails(
              id: id,
              title: id,
              description: id,
              price: '€4.99',
              rawPrice: 4.99,
              currencyCode: 'EUR',
            ),
        ],
        notFoundIDs: const [],
      );

  @override
  Future<bool> buy({
    required ProductDetails product,
    required String accountId,
    PurchaseDetails? replacing,
  }) async {
    bought.add((
      product: product.id,
      accountId: accountId,
      replacing: replacing?.productID,
    ));
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
    purchase.pendingCompletePurchase = false;
  }

  @override
  Future<void> restorePurchases({String? accountId}) async {
    restores++;
    scheduleMicrotask(() => controller.add(List.of(owned)));
  }
}

PurchaseDetails purchase(
  String productId,
  PurchaseStatus status, {
  String token = 'token-1',
}) =>
    PurchaseDetails(
        purchaseID: 'GPA.$token',
        productID: productId,
        verificationData: PurchaseVerificationData(
          localVerificationData: '{}',
          serverVerificationData: token,
          source: 'google_play',
        ),
        transactionDate: '0',
        status: status,
      )
      ..pendingCompletePurchase =
          status == PurchaseStatus.purchased ||
          status == PurchaseStatus.restored;

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('PlayBillingService', () {
    late FakeBillingPlatform store;
    late List<String> verified;
    late PlayVerifyOutcome Function(String token) verdict;
    late PlayBillingService billing;

    setUp(() {
      store = FakeBillingPlatform();
      verified = [];
      verdict = (_) => PlayVerifyOutcome(
        UpgradeResult.ok,
        tier: '3x',
        acknowledge: true,
        expiresAt: DateTime.utc(2026, 11, 11),
        autoRenewing: true,
      );
      billing = PlayBillingService(
        platform: store,
        uid: () => 'user-1',
        verifier:
            ({
              required String productId,
              required String purchaseToken,
              required String packageName,
            }) async {
              verified.add('$productId:$purchaseToken:$packageName');
              return verdict(purchaseToken);
            },
      );
    });

    tearDown(() => billing.dispose());

    test('loads localized products and re-checks owned purchases', () async {
      await billing.ensureLoaded();
      expect(billing.available, isTrue);
      expect(billing.productFor('7x')!.price, '€4.99');
      expect(billing.productFor('7x')!.id, kOvidPlayProducts['7x']);
      expect(store.restores, 1);
    });

    test('purchase is acknowledged only after server verification', () async {
      final result = billing.buy('3x');
      await settle();
      expect(store.bought.single.product, 'ovid_plus_monthly');
      expect(store.bought.single.accountId, ovidPlayAccountId('user-1'));
      expect(store.bought.single.accountId, hasLength(64));
      final p = purchase('ovid_plus_monthly', PurchaseStatus.purchased);
      store.controller.add([p]);
      final outcome = await result;
      expect(outcome.result, UpgradeResult.ok);
      expect(outcome.tier, '3x');
      expect(verified, ['ovid_plus_monthly:token-1:$kOvidPlayPackage']);
      expect(store.completed, [p]);
      expect(billing.ownedTier, '3x');
      expect(billing.expiresAt, DateTime.utc(2026, 11, 11));
    });

    test('an unverified purchase is never acknowledged', () async {
      for (final failure in [
        UpgradeResult.rejected,
        UpgradeResult.offline,
        UpgradeResult.unknown,
      ]) {
        verdict = (_) => PlayVerifyOutcome(failure);
        final result = billing.buy('3x');
        await settle();
        store.controller.add([
          purchase('ovid_plus_monthly', PurchaseStatus.purchased),
        ]);
        expect((await result).result, failure);
      }
      // Verified-but-inactive (expired/replaced) also must not be acknowledged.
      verdict = (_) => const PlayVerifyOutcome(UpgradeResult.ok, tier: 'free');
      final result = billing.buy('3x');
      await settle();
      store.controller.add([
        purchase('ovid_plus_monthly', PurchaseStatus.purchased),
      ]);
      expect((await result).result, UpgradeResult.rejected);
      expect(store.completed, isEmpty);
      expect(billing.ownedTier, isNull);
    });

    test('pending (deferred) payment waits without verifying', () async {
      final result = billing.buy('7x');
      await settle();
      store.controller.add([
        purchase('ovid_pro_monthly', PurchaseStatus.pending),
      ]);
      expect((await result).result, UpgradeResult.pending);
      expect(verified, isEmpty);
      expect(store.completed, isEmpty);
      // Payment clears later: the stream delivers it and it is verified.
      final p = purchase('ovid_pro_monthly', PurchaseStatus.purchased);
      store.controller.add([p]);
      await settle();
      await settle();
      expect(verified, hasLength(1));
      expect(store.completed, [p]);
    });

    test('server pending verdict is not acknowledged', () async {
      verdict = (_) => const PlayVerifyOutcome(UpgradeResult.pending);
      final result = billing.buy('3x');
      await settle();
      store.controller.add([
        purchase('ovid_plus_monthly', PurchaseStatus.purchased),
      ]);
      expect((await result).result, UpgradeResult.pending);
      expect(store.completed, isEmpty);
    });

    test('cancel and store errors map to distinct results', () async {
      var result = billing.buy('3x');
      await settle();
      store.controller.add([
        purchase('ovid_plus_monthly', PurchaseStatus.canceled),
      ]);
      expect((await result).result, UpgradeResult.cancelled);
      result = billing.buy('3x');
      await settle();
      store.controller.add([
        purchase('ovid_plus_monthly', PurchaseStatus.error)
          ..error = IAPError(
            source: 'google_play',
            code: 'BillingResponse.serviceUnavailable',
            message: 'network',
          ),
      ]);
      expect((await result).result, UpgradeResult.offline);
    });

    test('upgrade replaces the owned plan', () async {
      final first = billing.buy('3x');
      await settle();
      store.controller.add([
        purchase('ovid_plus_monthly', PurchaseStatus.purchased),
      ]);
      await first;
      verdict = (_) => const PlayVerifyOutcome(
        UpgradeResult.ok,
        tier: '15x',
        acknowledge: true,
      );
      final second = billing.buy('15x');
      await settle();
      expect(store.bought.last.replacing, 'ovid_plus_monthly');
      store.controller.add([
        purchase(
          'ovid_max_monthly',
          PurchaseStatus.purchased,
          token: 'token-2',
        ),
      ]);
      expect((await second).tier, '15x');
    });

    test('restore verifies owned subscriptions or reports none', () async {
      await billing.ensureLoaded();
      await settle();
      expect((await billing.restore()).result, UpgradeResult.nothingToRestore);
      final p = purchase('ovid_plus_monthly', PurchaseStatus.restored);
      store.owned = [p];
      final outcome = await billing.restore();
      expect(outcome.result, UpgradeResult.ok);
      expect(store.completed, [p]);
      expect(billing.ownedTier, '3x');
    });

    test('no Play store means plans are not available', () async {
      final offline = PlayBillingService(
        platform: FakeBillingPlatform(storeAvailable: false),
        uid: () => 'user-1',
        verifier:
            ({
              required String productId,
              required String purchaseToken,
              required String packageName,
            }) async => const PlayVerifyOutcome(UpgradeResult.ok),
      );
      expect((await offline.buy('3x')).result, UpgradeResult.notAvailable);
      expect(offline.available, isFalse);
      offline.dispose();
    });

    test('subscription centre deep link targets the product', () {
      final uri = playSubscriptionCenterUri(productId: 'ovid_plus_monthly');
      expect(uri.host, 'play.google.com');
      expect(uri.path, '/store/account/subscriptions');
      expect(uri.queryParameters, {
        'sku': 'ovid_plus_monthly',
        'package': kOvidPlayPackage,
      });
      expect(PlayBillingService.billingPeriodLabel('P1M'), 'month');
      expect(PlayBillingService.billingPeriodLabel('P1Y'), 'year');
    });
  });

  group('OvidCloudService.verifyPlayPurchase', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
      OvidCloudService.idTokenOverrideForTest = () async => 'billing-token';
    });

    tearDown(() {
      OvidCloudService.idTokenOverrideForTest = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    Future<PlayVerifyOutcome> verifyWith(http.Response response) async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/billing/verify') return response;
        return http.Response('{"data":[]}', 200);
      });
      final outcome = await OvidCloudService.I.verifyPlayPurchase(
        productId: 'ovid_plus_monthly',
        purchaseToken: 'tok',
        packageName: kOvidPlayPackage,
        client: client,
      );
      final verify = requests.firstWhere(
        (r) => r.url.path == '/billing/verify',
      );
      expect(jsonDecode(verify.body), {
        'product_id': 'ovid_plus_monthly',
        'purchase_token': 'tok',
        'package_name': kOvidPlayPackage,
      });
      return outcome;
    }

    test('server-verified purchase sets the tier', () async {
      final outcome = await verifyWith(
        http.Response(
          jsonEncode({
            'ok': true,
            'status': 'active',
            'tier': '3x',
            'expires_at': '2026-11-11T08:00:00Z',
            'auto_renewing': true,
            'acknowledge': true,
          }),
          200,
        ),
      );
      expect(outcome.result, UpgradeResult.ok);
      expect(outcome.acknowledge, isTrue);
      expect(outcome.expiresAt, DateTime.utc(2026, 11, 11, 8));
      expect(AppState.I.ovidCloudTier, '3x');
    });

    test('rejected, pending and disabled verdicts do not set a tier', () async {
      final cases = {
        http.Response('{"ok":false,"error":{"code":"account_mismatch"}}', 403):
            UpgradeResult.rejected,
        http.Response('{"ok":false,"status":"pending"}', 202):
            UpgradeResult.pending,
        http.Response(
          '{"ok":false,"error":{"code":"billing_unavailable"}}',
          503,
        ): UpgradeResult.notAvailable,
        http.Response('{"ok":false,"error":{"code":"play_unavailable"}}', 503):
            UpgradeResult.unknown,
      };
      for (final entry in cases.entries) {
        final outcome = await verifyWith(entry.key);
        expect(outcome.result, entry.value);
        expect(outcome.acknowledge, isFalse);
        expect(AppState.I.ovidCloudTier, 'free');
      }
    });
  });
}
