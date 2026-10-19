// Wave 3: Play billing per-account state (SH-013), the buy() timeout
// (SH-014) and the "payment received, confirming" outcome (SH-002).

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';

import 'fake_billing_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('switching accounts clears the previous plan (SH-013)', () async {
    final store = FakeBillingPlatform()
      ..owned = [purchase('ovid_pro_monthly', PurchaseStatus.restored)];
    var uid = 'user-a';
    final billing = PlayBillingService(
      platform: store,
      uid: () => uid,
      verifier: ({
        required String productId,
        required String purchaseToken,
        required String packageName,
      }) async =>
          PlayVerifyOutcome(
            UpgradeResult.ok,
            tier: ovidTierForProduct(productId),
            acknowledge: true,
            expiresAt: DateTime.utc(2026, 11, 1),
          ),
    );
    await billing.ensureLoaded();
    await pumpEventQueue();
    expect(billing.ownedTier, '7x');
    expect(billing.expiresAt, isNotNull);

    // B signs in; B owns nothing on Play.
    uid = 'user-b';
    store.owned = [];
    await billing.ensureLoaded();
    await pumpEventQueue();

    expect(billing.ownedTier, isNull);
    expect(billing.ownedProductId, isNull);
    expect(billing.expiresAt, isNull);
    expect(store.restores, 2, reason: "B's purchases are re-read");
    billing.dispose();
  });

  test('resetForAccount clears owned state explicitly', () async {
    final store = FakeBillingPlatform()
      ..owned = [purchase('ovid_plus_monthly', PurchaseStatus.restored)];
    final billing = fakeBillingService(store);
    await billing.ensureLoaded();
    await pumpEventQueue();
    expect(billing.ownedTier, '3x');

    billing.resetForAccount();
    expect(billing.ownedTier, isNull);
    expect(billing.autoRenewing, isNull);
    billing.dispose();
  });

  test('a purchase Play never answers times out (SH-014)', () async {
    final store = FakeBillingPlatform(); // no autoResult: Play stays silent
    final billing = PlayBillingService(
      platform: store,
      uid: () => 'user-1',
      verifier: ({
        required String productId,
        required String purchaseToken,
        required String packageName,
      }) async =>
          const PlayVerifyOutcome(UpgradeResult.ok),
      purchaseTimeout: const Duration(milliseconds: 50),
    );
    final outcome = await billing.buy('3x');
    expect(outcome.result, UpgradeResult.unknown);

    // The plan's button works again: a second buy starts a new sheet.
    final second = billing.buy('3x');
    await pumpEventQueue();
    expect(store.bought, hasLength(2));
    billing.abandonPurchase('3x');
    expect((await second).result, UpgradeResult.unknown);
    billing.dispose();
  });

  for (final failure in [
    UpgradeResult.notAvailable,
    UpgradeResult.unknown,
    UpgradeResult.offline,
  ]) {
    test('a paid purchase the server cannot confirm ($failure) is '
        '"confirming", never "Nothing was charged" (SH-002)', () async {
      final store = FakeBillingPlatform(autoResult: PurchaseStatus.purchased);
      final billing = fakeBillingService(
        store,
        verdict: (_) => PlayVerifyOutcome(failure),
      );
      final outcome = await billing.buy('7x');
      expect(outcome.result, UpgradeResult.confirming);
      expect(store.completed, isEmpty,
          reason: 'never acknowledged before the server confirms');
      billing.dispose();
    });
  }

  test('resume re-verifies an unconfirmed purchase', () async {
    final store = FakeBillingPlatform();
    final billing = fakeBillingService(store);
    await billing.ensureLoaded();
    await pumpEventQueue();
    expect(store.restores, 1);
    await billing.recheckOnResume();
    expect(store.restores, 2);
    billing.dispose();
  });
}
