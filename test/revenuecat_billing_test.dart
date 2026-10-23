
// Money-safety contract, in one place:
//
//   resolveBillingRoute() decides which store may charge, and
//   RevenueCatBilling.buy() refuses before the store sheet when the purchase
//   could not be unlocked server-side. Both are asserted here.
//
// A widget-level version of this was attempted in
// test/v2/app/billing_purchase_confirmation_test.dart and removed: it drove
// V2SettingsActions.buyPlan, which awaits the real Play Billing plugin, so the
// test hung on a store that never answers. Testing through a plugin that
// cannot be faked proves nothing; the route decision above is the invariant
// that matters, and it needs no store.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/core/revenuecat_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake RevenueCat SDK. No plugin channel is touched.
class _FakePlatform implements RevenueCatPlatform {
  _FakePlatform({
    this.offeredPackages = const [],
    this.purchaseResult = const RevenueCatResult(ok: true, tier: '7x'),
    this.restoreResult = const RevenueCatResult(ok: true, tier: '3x'),
    this.infoResult = const RevenueCatResult(ok: true, tier: '7x'),
    this.failConfigure = false,
    this.throwOnPurchase = false,
  });

  final List<RevenueCatPackage> offeredPackages;
  final RevenueCatResult purchaseResult;
  final RevenueCatResult restoreResult;
  final RevenueCatResult infoResult;
  final bool failConfigure;
  final bool throwOnPurchase;

  int configureCalls = 0;
  int infoCalls = 0;
  String? configuredUser;
  String? configuredApiKey;
  String? purchasedIdentifier;

  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {
    if (failConfigure) throw StateError('configure failed');
    configureCalls++;
    configuredUser = appUserId;
    configuredApiKey = apiKey;
  }

  @override
  Future<List<RevenueCatPackage>> packages() async => offeredPackages;

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async {
    if (throwOnPurchase) throw StateError('purchase failed');
    purchasedIdentifier = identifier;
    return purchaseResult;
  }

  @override
  Future<RevenueCatResult> restore() async => restoreResult;

  @override
  Future<RevenueCatResult> customerInfo() async {
    infoCalls++;
    return infoResult;
  }
}

RevenueCatPackage _pkg(String productId, {String? identifier}) =>
    RevenueCatPackage(
      identifier: identifier ?? productId,
      productId: productId,
      title: productId,
      priceString: '\$1',
    );

/// A billing instance that talks to a fake SDK with a key compiled in.
RevenueCatBilling _billing(
  _FakePlatform fake, {
  RevenueCatConfig? config,
  bool? testStore,
  bool? releaseMode,
  void Function(String tier)? applyTier,
}) => RevenueCatBilling(
  platform: fake,
  uid: () => 'u1',
  config:
      config ??
      (testStore ?? false
          ? const RevenueCatConfig(apiKey: 'test_test_key', testStore: true)
          : const RevenueCatConfig(apiKey: 'goog_test_key')),
  testStore: testStore,
  releaseMode: releaseMode,
  // These tests exercise package matching, not the webhook gate; the gate is
  // covered separately below.
  serverConfirmation: true,
  // Reconcile tests assume RevenueCat is the purchase path; in the app Play
  // is preferred and its purchases never appear in RevenueCat.
  playActive: () => false,
  applyTier: applyTier,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    resetConfirmedPlanTierForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
    resetConfirmedPlanTierForTest();
  });

  test('tier and entitlement maps stay aligned with the Play products', () {
    expect(kRevenueCatEntitlements, {'3x': 'go', '7x': 'plus', '15x': 'pro'});
    for (final entry in kRevenueCatEntitlements.entries) {
      expect(ovidTierForEntitlement(entry.value), entry.key);
      expect(kOvidPlayProducts.containsKey(entry.key), isTrue);
      for (final period in OvidBillingPeriod.values) {
        final productId = ovidPlayProductId(entry.key, period);
        expect(productId, isNotNull, reason: '${entry.key} $period');
        expect(ovidTierForProduct(productId!), entry.key);
        expect(ovidPeriodForProduct(productId), period);
      }
    }
    expect(ovidTierForEntitlement('unknown'), isNull);
  });

  group('build configuration', () {
    test('no SDK key is baked into the source; the define is required', () {
      expect(kRevenueCatGoogleKey, isEmpty);
      expect(kRevenueCatTestStoreKey, isEmpty);
      // This test process is built without the defines, so RevenueCat is off
      // and the server-verified Play flow is the only purchase path.
      expect(kRevenueCatConfig.available, isFalse);
      expect(kRevenueCatConfig.error, isNotNull);
      expect(kRevenueCatConfig.testStore, isFalse);
      expect(RevenueCatBilling.I.available, isFalse);
    });

    test('a release build refuses the Test Store even with the define', () {
      final config = resolveRevenueCatConfig(
        releaseMode: true,
        testStoreRequested: true,
        googleKey: 'goog_release',
        testStoreKey: 'test_key',
      );
      expect(config.testStore, isFalse);
      expect(config.available, isTrue);
      expect(config.apiKey, 'goog_release');
      expect(
        demoGrantAllowed(releaseMode: true, testStore: true),
        isFalse,
        reason: 'the demo grant must never exist in a release build',
      );

      // The injected releaseMode also wins over a hand-passed test-store
      // config, so no call site can re-enable the demo.
      final billing = _billing(
        _FakePlatform(offeredPackages: const []),
        config: const RevenueCatConfig(apiKey: 'goog_release', testStore: true),
        releaseMode: true,
      );
      expect(billing.usingTestStore, isFalse);
      expect(billing.apiKey, 'goog_release');
    });

    test('a release build without the Google key disables RevenueCat', () {
      final config = resolveRevenueCatConfig(
        releaseMode: true,
        testStoreRequested: false,
        googleKey: '',
        testStoreKey: 'test_key',
      );
      expect(config.available, isFalse);
      expect(config.testStore, isFalse);
      expect(config.error, contains('OVID_REVENUECAT_GOOGLE_KEY'));
    });

    group('billing demo (Play monetization not approved yet)', () {
      tearDown(() {
        Distribution.billingDemoOverrideForTest = null;
        Distribution.productionOverrideForTest = null;
      });

      test('a production artifact can never grant a plan for free', () {
        Distribution.productionOverrideForTest = true;
        expect(
          demoGrantAllowed(releaseMode: true, testStore: true),
          isFalse,
          reason: 'a build that can reach real users must never demo-grant',
        );
      });

      test('an internal Play track may demo (it is not production)', () {
        // The internal track is also a Play artifact. Gating the demo on the
        // Play channel would have made it untestable exactly where it is used.
        Distribution.productionOverrideForTest = false;
        Distribution.billingDemoOverrideForTest = true;
        expect(
          demoGrantAllowed(releaseMode: true, testStore: true),
          isTrue,
        );
      });

      test('an opted-in sideload release build may grant, and says so', () {
        Distribution.billingDemoOverrideForTest = true;
        expect(
          demoGrantAllowed(releaseMode: true, testStore: true),
          isTrue,
          reason: 'an internal test build needs a working paywall',
        );
        // The plan name carries the marker so a demo plan never reads as a
        // real subscription.
        expect(ovidPlanName('7x'), contains('(demo)'));
      });

      test('the demo route outranks an unavailable store', () {
        Distribution.billingDemoOverrideForTest = true;
        final billing = _billing(
          _FakePlatform(offeredPackages: const []),
          config: const RevenueCatConfig(apiKey: '', testStore: false),
          releaseMode: true,
        );
        final route = resolveBillingRoute(
          playLoaded: true,
          playAvailable: false,
          revenueCat: billing,
        );
        expect(
          route,
          BillingRoute.demo,
          reason: 'a disabled CTA would make the paywall untestable',
        );
      });

      test('without the opt-in the plan name carries no marker', () {
        Distribution.billingDemoOverrideForTest = false;
        expect(ovidPlanName('7x'), isNot(contains('(demo)')));
      });
    });

    test('the Test Store needs the explicit non-release opt-in', () {
      expect(demoGrantAllowed(releaseMode: false, testStore: false), isFalse);
      expect(demoGrantAllowed(releaseMode: false, testStore: true), isTrue);

      final demo = resolveRevenueCatConfig(
        releaseMode: false,
        testStoreRequested: true,
        googleKey: '',
        testStoreKey: '',
      );
      expect(demo.testStore, isTrue);
      // A debug/profile demo build works without a shipped Test Store key.
      expect(demo.available, isFalse);

      final off = resolveRevenueCatConfig(
        releaseMode: false,
        testStoreRequested: false,
        googleKey: 'goog_debug',
        testStoreKey: 'test_key',
      );
      expect(off.testStore, isFalse);
      expect(off.apiKey, 'goog_debug');
    });

    test('debug builds may inject a real Test Store key', () {
      final config = resolveRevenueCatConfig(
        releaseMode: false,
        testStoreRequested: true,
        googleKey: 'goog_debug',
        testStoreKey: 'test_debug',
      );
      expect(config.testStore, isTrue);
      expect(config.apiKey, 'test_debug');
    });
  });

  test('configure is idempotent per user', () async {
    final fake = _FakePlatform();
    final billing = _billing(fake);
    expect(await billing.configure(), isTrue);
    expect(await billing.configure(), isTrue);
    expect(fake.configureCalls, 1);
    expect(fake.configuredUser, 'u1');
    expect(fake.configuredApiKey, 'goog_test_key');

    await billing.configure(uid: 'u2');
    expect(fake.configureCalls, 2);
    expect(fake.configuredUser, 'u2');
  });

  test('configure refuses an empty uid', () async {
    final fake = _FakePlatform();
    final billing = RevenueCatBilling(
      platform: fake,
      uid: () => '',
      config: const RevenueCatConfig(apiKey: 'goog_test_key'),
    );
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
    final outcome = await _billing(fake).buy('15x');
    expect(outcome.result, UpgradeResult.ok);
    expect(outcome.tier, '15x');
    expect(fake.purchasedIdentifier, 'pkg_max');
  });

  test('buying yearly resolves the yearly package', () async {
    final fake = _FakePlatform(
      offeredPackages: [
        _pkg('ovid_plus_monthly', identifier: 'pkg_go_monthly'),
        _pkg('ovid_plus_yearly', identifier: 'pkg_go_yearly'),
        _pkg('ovid_pro_yearly', identifier: 'pkg_plus_yearly'),
      ],
      purchaseResult: const RevenueCatResult(ok: true, tier: '3x'),
    );
    final billing = _billing(fake);
    final outcome = await billing.buy('3x', period: OvidBillingPeriod.yearly);
    expect(outcome.result, UpgradeResult.ok);
    expect(fake.purchasedIdentifier, 'pkg_go_yearly');
    expect(billing.lastPurchaseError, isNull);
  });

  test('a missing yearly package never falls back to monthly', () async {
    // The offering only has monthly packages, including RevenueCat's
    // conventional monthly one. A yearly request must not buy any of them.
    final fake = _FakePlatform(
      offeredPackages: [
        _pkg('ovid_plus_monthly', identifier: r'$rc_monthly'),
        _pkg('ovid_pro_monthly', identifier: 'pkg_plus'),
      ],
    );
    final billing = _billing(fake);
    final outcome = await billing.buy('3x', period: OvidBillingPeriod.yearly);
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(fake.purchasedIdentifier, isNull);
    expect(billing.lastPurchaseWasDemo, isFalse);
    expect(billing.lastPurchaseError, contains('Yearly'));
  });

  test('monthly still buys the monthly package when yearly exists', () async {
    final fake = _FakePlatform(
      offeredPackages: [
        _pkg('ovid_plus_yearly', identifier: 'pkg_go_yearly'),
        _pkg('ovid_plus_monthly', identifier: 'pkg_go_monthly'),
      ],
      purchaseResult: const RevenueCatResult(ok: true, tier: '3x'),
    );
    final outcome = await _billing(fake).buy('3x');
    expect(outcome.result, UpgradeResult.ok);
    expect(fake.purchasedIdentifier, 'pkg_go_monthly');
  });

  test(
    'a missing monthly product may use the monthly package, not yearly',
    () async {
      final fake = _FakePlatform(
        offeredPackages: [
          _pkg('ovid_plus_yearly', identifier: 'pkg_go_yearly'),
          _pkg('legacy_go_monthly', identifier: r'$rc_monthly'),
        ],
        purchaseResult: const RevenueCatResult(ok: true, tier: '3x'),
      );
      final outcome = await _billing(fake).buy('3x');
      expect(outcome.result, UpgradeResult.ok);
      expect(fake.purchasedIdentifier, r'$rc_monthly');
    },
  );

  test('the monthly fallback refuses a package from another tier', () async {
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_max_monthly', identifier: r'$rc_monthly')],
    );
    final billing = _billing(fake);
    final outcome = await billing.buy('3x');
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(fake.purchasedIdentifier, isNull);
  });

  test('the monthly fallback never buys a yearly product', () async {
    // A misconfigured offering could put a yearly SKU in the `$rc_monthly`
    // slot; a monthly selection must not be charged for a year.
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_plus_yearly', identifier: r'$rc_monthly')],
    );
    final outcome = await _billing(fake).buy('3x');
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(fake.purchasedIdentifier, isNull);
  });

  test('buy without an offered package is not available', () async {
    final fake = _FakePlatform(offeredPackages: [_pkg('some_other')]);
    final billing = _billing(fake);
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(fake.purchasedIdentifier, isNull);
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test(
    'a chargeable RevenueCat build without the webhook never charges',
    () async {
      final fake = _FakePlatform(
        offeredPackages: [_pkg('ovid_plus_monthly', identifier: 'pkg_go')],
      );
      final billing = RevenueCatBilling(
        platform: fake,
        uid: () => 'u1',
        config: const RevenueCatConfig(apiKey: 'goog_test_key'),
      );
      // No `OVID_REVENUECAT_SERVER_CONFIRMATION`: the SDK must not even open.
      expect(billing.serverConfirmationAvailable, isFalse);
      final outcome = await billing.buy('3x');
      expect(outcome.result, UpgradeResult.notAvailable);
      expect(fake.purchasedIdentifier, isNull);
      expect(billing.lastPurchaseError, kRevenueCatUnconfirmedReason);
    },
  );

  test('Play wins; unconfirmed RevenueCat is only reached when Play is absent', () {
    final billing = RevenueCatBilling(
      platform: _FakePlatform(),
      uid: () => 'u1',
      config: const RevenueCatConfig(apiKey: 'goog_test_key'),
    );
    expect(
      resolveBillingRoute(
        playLoaded: true,
        playAvailable: true,
        revenueCat: billing,
      ),
      BillingRoute.play,
    );
    expect(
      resolveBillingRoute(
        playLoaded: true,
        playAvailable: false,
        revenueCat: billing,
      ),
      BillingRoute.none,
    );
  });

  test(
    'test store with no offering grants a labelled demo entitlement',
    () async {
      final fake = _FakePlatform(offeredPackages: const []);
      final billing = _billing(fake, testStore: true);
      expect(billing.usingTestStore, isTrue);
      final outcome = await billing.buy('7x');
      expect(outcome.result, UpgradeResult.ok);
      expect(outcome.tier, '7x');
      expect(billing.lastPurchaseWasDemo, isTrue);
    },
  );

  test('a demo build works from the define alone (no key shipped)', () async {
    final fake = _FakePlatform(offeredPackages: const []);
    final billing = _billing(
      fake,
      config: const RevenueCatConfig(testStore: true),
    );
    expect(billing.usingTestStore, isTrue);
    expect(billing.available, isTrue, reason: 'the local demo needs no key');
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.ok);
    expect(billing.lastPurchaseWasDemo, isTrue);
    expect(fake.configureCalls, 0, reason: 'nothing is queried');
  });

  test('test store with a real package uses the store, not the demo', () async {
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_pro_monthly', identifier: 'pkg_plus')],
      purchaseResult: const RevenueCatResult(ok: true, tier: '7x'),
    );
    final billing = _billing(
      fake,
      config: const RevenueCatConfig(apiKey: 'test_debug', testStore: true),
    );
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.ok);
    expect(fake.purchasedIdentifier, 'pkg_plus');
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test('a purchase that throws in a release build does not grant', () async {
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_pro_monthly', identifier: 'pkg_plus')],
      throwOnPurchase: true,
    );
    final billing = _billing(
      fake,
      config: const RevenueCatConfig(apiKey: 'goog_release', testStore: true),
      releaseMode: true,
    );
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.unknown);
    expect(outcome.tier, isNull);
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test('a missing package in a release build is not a demo grant', () async {
    final fake = _FakePlatform(offeredPackages: const []);
    final billing = _billing(fake, releaseMode: true, testStore: true);
    final outcome = await billing.buy('7x');
    expect(outcome.result, UpgradeResult.notAvailable);
    expect(billing.lastPurchaseWasDemo, isFalse);
  });

  test('buy for an unknown tier is rejected', () async {
    final fake = _FakePlatform();
    final outcome = await _billing(fake).buy('99x');
    expect(outcome.result, UpgradeResult.rejected);
  });

  test('a configure failure makes buy fail safely', () async {
    final fake = _FakePlatform(failConfigure: true);
    final outcome = await _billing(fake).buy('7x');
    expect(outcome.result, UpgradeResult.rejected);
    expect(fake.purchasedIdentifier, isNull);
  });

  test('restore and currentTier read the entitlement', () async {
    final fake = _FakePlatform(
      restoreResult: const RevenueCatResult(ok: true, tier: '3x'),
      infoResult: const RevenueCatResult(ok: true, tier: '7x'),
    );
    final billing = _billing(fake);
    expect((await billing.restore()).tier, '3x');
    expect(await billing.currentTier(), '7x');
  });

  test('restore with no purchase reports nothing to restore', () async {
    final fake = _FakePlatform(
      restoreResult: const RevenueCatResult(ok: false),
    );
    expect(
      (await _billing(fake).restore()).result,
      UpgradeResult.nothingToRestore,
    );
  });

  test('a failed restore is not reported as nothing to restore', () async {
    final fake = _FakePlatform(
      restoreResult: const RevenueCatResult(ok: false, error: 'network'),
    );
    expect(
      (await _billing(fake).restore()).result,
      isNot(UpgradeResult.nothingToRestore),
    );
  });

  test('a purchase with no entitlement yet is confirming, not rejected', () async {
    final fake = _FakePlatform(
      offeredPackages: [_pkg('ovid_pro_monthly')],
      purchaseResult: const RevenueCatResult(ok: false),
    );
    expect(
      (await _billing(fake).buy('7x')).result,
      UpgradeResult.confirming,
    );
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

  group('entitlement reconciliation', () {
    testWidgets('a missing entitlement clears the cached plan on resume', (
      tester,
    ) async {
      final applied = <String>[];
      final fake = _FakePlatform(infoResult: const RevenueCatResult(ok: false));
      final billing = _billing(fake, applyTier: applied.add);

      billing.start();
      await tester.pump();
      expect(applied, ['free'], reason: 'launch reconciliation');
      expect(fake.infoCalls, 1);

      billing.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(fake.infoCalls, 2, reason: 'resume reconciliation');
      expect(applied, ['free', 'free']);
    });

    testWidgets('an active entitlement only clears when it is gone', (
      tester,
    ) async {
      final applied = <String>[];
      final fake = _FakePlatform(
        infoResult: const RevenueCatResult(ok: true, tier: '7x'),
      );
      final billing = _billing(fake, applyTier: applied.add);
      billing.start();
      await tester.pump();
      expect(applied, isEmpty, reason: 'the store never unlocks a plan');
      expect(await billing.reconcile(), '7x');
      expect(applied, isEmpty);
    });

    testWidgets('an unreachable store does not wipe a paying plan', (
      tester,
    ) async {
      final applied = <String>[];
      // ok=false *with an error*: the entitlement list could not be read.
      final fake = _FakePlatform(
        infoResult: const RevenueCatResult(ok: false, error: 'offline'),
      );
      final billing = _billing(fake, applyTier: applied.add);
      expect(await billing.reconcile(), isNull);
      expect(applied, isEmpty);
    });

    test('the test-store demo build has nothing to reconcile', () async {
      final fake = _FakePlatform();
      final billing = RevenueCatBilling(
        platform: fake,
        uid: () => 'u1',
        testStore: true,
      );
      expect(await billing.reconcile(), isNull);
      expect(fake.infoCalls, 0);
    });
  });

  group('server-confirmed plan gate', () {
    test('nothing is confirmed until a source of truth answers', () async {
      expect(isServerConfirmed('free'), isFalse);
      expect(isServerConfirmed('7x'), isFalse);
      expect(confirmedPlanTier, isNull);

      expect(await applyPurchasedPlan('7x', fetch: () async => null), isFalse);
      expect(AppState.I.ovidCloudTier, 'free');
      expect(isServerConfirmed('7x'), isFalse);
    });

    test('a purchase unlocks only on the server answer', () async {
      expect(await applyPurchasedPlan('7x', fetch: () async => '7x'), isTrue);
      expect(AppState.I.ovidCloudTier, '7x');
      expect(isServerConfirmed('7x'), isTrue);
      expect(isServerConfirmed('free'), isFalse);
    });

    test('a server that still says free does not unlock', () async {
      expect(
        await applyPurchasedPlan('15x', fetch: () async => 'free'),
        isFalse,
      );
      expect(AppState.I.ovidCloudTier, 'free');
      expect(isServerConfirmed('15x'), isFalse);
    });

    test('a failing server call is never a confirmation', () async {
      expect(
        await applyPurchasedPlan(
          '7x',
          fetch: () async => throw StateError('offline'),
        ),
        isFalse,
      );
      expect(AppState.I.ovidCloudTier, 'free');
      expect(isServerConfirmed('7x'), isFalse);
    });

    test('the server tier, not the purchased one, is written', () async {
      expect(await applyPurchasedPlan('3x', fetch: () async => '15x'), isTrue);
      expect(AppState.I.ovidCloudTier, '15x');
      expect(isServerConfirmed('15x'), isTrue);
      expect(isServerConfirmed('3x'), isFalse);
    });

    test('the debug demo unlock never runs in a release build', () async {
      if (kReleaseMode) {
        expect(await applyPurchasedPlan('7x', demo: true), isFalse);
        expect(AppState.I.ovidCloudTier, 'free');
      } else {
        expect(await applyPurchasedPlan('7x', demo: true), isTrue);
        expect(AppState.I.ovidCloudTier, '7x');
        expect(isServerConfirmed('7x'), isTrue);
      }
    });

    test('an unknown confirmed tier clears the confirmation', () {
      confirmPlanTier('7x');
      expect(isServerConfirmed('7x'), isTrue);
      confirmPlanTier('future-tier');
      expect(confirmedPlanTier, isNull);
      expect(isServerConfirmed('7x'), isFalse);
      confirmPlanTier('free');
      expect(isServerConfirmed('free'), isTrue);
    });
  });
}
