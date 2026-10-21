import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/revenuecat_billing.dart';

/// Fake RevenueCat SDK. No plugin channel is touched.
class _FakePlatform implements RevenueCatPlatform {
  _FakePlatform({
    this.offeredPackages = const [],
    this.purchaseResult = const RevenueCatResult(ok: true, tier: '7x'),
    this.restoreResult = const RevenueCatResult(ok: true, tier: '3x'),
    this.infoResult = const RevenueCatResult(ok: true, tier: '7x'),
    this.failConfigure = false,
  });

  final List<RevenueCatPackage> offeredPackages;
  final RevenueCatResult purchaseResult;
  final RevenueCatResult restoreResult;
  final RevenueCatResult infoResult;
  final bool failConfigure;

  int configureCalls = 0;
  String? configuredUser;
  String? purchasedIdentifier;

  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {
    if (failConfigure) throw StateError('configure failed');
    configureCalls++;
    configuredUser = appUserId;
  }

  @override
  Future<List<RevenueCatPackage>> packages() async => offeredPackages;

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async {
    purchasedIdentifier = identifier;
    return purchaseResult;
  }

  @override
  Future<RevenueCatResult> restore() async => restoreResult;

  @override
  Future<RevenueCatResult> customerInfo() async => infoResult;
}

RevenueCatPackage _pkg(String productId, {String? identifier}) =>
    RevenueCatPackage(
      identifier: identifier ?? productId,
      productId: productId,
      title: productId,
      priceString: '\$1',
    );

void main() {
  test('tier and entitlement maps stay aligned with the Play products', () {
    expect(kRevenueCatEntitlements, {
      '3x': 'go',
      '7x': 'plus',
      '15x': 'pro',
    });
    for (final entry in kRevenueCatEntitlements.entries) {
      expect(ovidTierForEntitlement(entry.value), entry.key);
      expect(kOvidPlayProducts.containsKey(entry.key), isTrue);
    }
    expect(ovidTierForEntitlement('unknown'), isNull);
  });

  test('the public SDK key ships with the app', () {
    expect(kRevenueCatGoogleKey.startsWith('goog_'), isTrue);
    expect(RevenueCatBilling.I.available, isTrue);
  });

  test('configure is idempotent per user', () async {
    final fake = _FakePlatform();
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    expect(await billing.configure(), isTrue);
    expect(await billing.configure(), isTrue);
    expect(fake.configureCalls, 1);
    expect(fake.configuredUser, 'u1');

    await billing.configure(uid: 'u2');
    expect(fake.configureCalls, 2);
    expect(fake.configuredUser, 'u2');
  });

  test('configure refuses an empty uid', () async {
    final fake = _FakePlatform();
    final billing = RevenueCatBilling(platform: fake, uid: () => '');
    expect(await billing.configure(), isFalse);
    expect(fake.configureCalls, 0);
  });

  test('buy matches the Play product for the tier', () async {
    final fake = _FakePlatform(
      offeredPackages: [
        _pkg('ovid_plus_monthly', identifier: 'pkg_plus'),
        _pkg('ovid_max_monthly', identifier: 'pkg_max'),
      ],
      purchaseResult: const RevenueCatResult(ok: true, tier: '15x'),
    );
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    final outcome = await billing.buy('15x');
    expect(outcome.result, UpgradeResult.ok);
    expect(outcome.tier, '15x');
    expect(fake.purchasedIdentifier, 'pkg_max');
  });

  test('buy without an offered package is not available', () async {
    final fake = _FakePlatform(offeredPackages: [_pkg('some_other')]);
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(fake.purchasedIdentifier, isNull);
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test('test store with no offering grants a labelled demo entitlement', () async {
    final fake = _FakePlatform(offeredPackages: const []);
    final billing = RevenueCatBilling(
      platform: fake,
      uid: () => 'u1',
      testStore: true,
    );
    expect(billing.usingTestStore, isTrue);
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.ok);
    expect(outcome.tier, '7x');
    expect(billing.lastPurchaseWasDemo, isTrue);
  });

  test('test store with a real package uses the store, not the demo', () async {
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_pro_monthly', identifier: 'pkg_plus')],
      purchaseResult: const RevenueCatResult(ok: true, tier: '7x'),
    );
    final billing = RevenueCatBilling(
      platform: fake,
      uid: () => 'u1',
      testStore: true,
    );
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.ok);
    expect(fake.purchasedIdentifier, 'pkg_plus');
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test('buy for an unknown tier is rejected', () async {
    final fake = _FakePlatform();
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    final outcome = await billing.buy('99x');
    expect(outcome.result, UpgradeResult.rejected);
  });

  test('a configure failure makes buy fail safely', () async {
    final fake = _FakePlatform(failConfigure: true);
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.rejected);
    expect(fake.purchasedIdentifier, isNull);
  });

  test('restore and currentTier read the entitlement', () async {
    final fake = _FakePlatform(
      restoreResult: const RevenueCatResult(ok: true, tier: '3x'),
      infoResult: const RevenueCatResult(ok: true, tier: '7x'),
    );
    final billing = RevenueCatBilling(platform: fake, uid: () => 'u1');
    expect((await billing.restore()).tier, '3x');
    expect(await billing.currentTier(), '7x');
  });

  test('cancel is reported as cancelled, not rejected', () {
    expect(
      const RevenueCatResult.cancelled().toOutcome().result,
      UpgradeResult.cancelled,
    );
  });

  test('a successful result carries tier and expiry', () {
    final expiry = DateTime.utc(2026, 11, 21);
    final outcome = RevenueCatResult(
      ok: true,
      tier: '15x',
      expiresAt: expiry,
    ).toOutcome();
    expect(outcome.result, UpgradeResult.ok);
    expect(outcome.tier, '15x');
    expect(outcome.expiresAt, expiry);
  });

  test('a failed result is rejected without a tier', () {
    final outcome = const RevenueCatResult(ok: false).toOutcome();
    expect(outcome.result, UpgradeResult.rejected);
    expect(outcome.tier, isNull);
  });
}
