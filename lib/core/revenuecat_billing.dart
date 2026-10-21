import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'diag.dart';
import 'play_billing.dart';
import 'ovid_cloud_service.dart';

/// RevenueCat is the purchase/entitlement layer required by the product spec.
///
/// The Google public SDK key is injected at build time:
/// `--dart-define=OVID_REVENUECAT_GOOGLE_KEY=goog_...`.
/// When it is empty the app falls back to the existing server-verified Google
/// Play flow, so a build without RevenueCat still sells correctly.
///
/// Entitlement ids (RevenueCat dashboard) map 1:1 to Ovid tiers:
/// `go` → `3x`, `plus` → `7x`, `pro` → `15x`.
const String kRevenueCatGoogleKey = String.fromEnvironment(
  'OVID_REVENUECAT_GOOGLE_KEY',
  // Public SDK key for the Ovid Si Play Store app in RevenueCat project
  // `afe58e73`. Public by design (it ships inside every app); override with
  // --dart-define for a different project.
  defaultValue: 'goog_ZicbEfueBOLBmUkaNNziRbddetJ',
);

/// Public SDK key for the RevenueCat **Test Store** app in the same project.
/// Test Store purchases never charge a card, so internal-testing builds can
/// exercise the whole paywall before Play subscriptions exist.
const String kRevenueCatTestStoreKey = String.fromEnvironment(
  'OVID_REVENUECAT_TEST_STORE_KEY',
  defaultValue: 'test_emXiVDcEQgNfzAGwNjbihcXxuyY',
);

/// When true the app configures the RevenueCat Test Store instead of Google
/// Play. Set with `--dart-define=OVID_REVENUECAT_TEST_STORE=true` for tester
/// builds only; never for production.
const bool kRevenueCatTestStore = bool.fromEnvironment(
  'OVID_REVENUECAT_TEST_STORE',
);

/// RevenueCat entitlement id per Ovid tier.
const Map<String, String> kRevenueCatEntitlements = {
  '3x': 'go',
  '7x': 'plus',
  '15x': 'pro',
};

/// Tier for a RevenueCat entitlement id, or null when it is not an Ovid plan.
String? ovidTierForEntitlement(String entitlementId) {
  for (final entry in kRevenueCatEntitlements.entries) {
    if (entry.value == entitlementId) return entry.key;
  }
  return null;
}

/// One purchasable RevenueCat package, reduced to what the app needs.
@immutable
class RevenueCatPackage {
  const RevenueCatPackage({
    required this.identifier,
    required this.productId,
    required this.title,
    required this.priceString,
  });

  final String identifier;
  final String productId;
  final String title;
  final String priceString;
}

/// The outcome of a RevenueCat call, decoupled from the plugin for tests.
@immutable
class RevenueCatResult {
  const RevenueCatResult({
    required this.ok,
    this.tier,
    this.expiresAt,
    this.error,
    this.cancelled = false,
  });

  const RevenueCatResult.cancelled()
    : ok = false,
      tier = null,
      expiresAt = null,
      error = null,
      cancelled = true;

  final bool ok;
  final String? tier;
  final DateTime? expiresAt;
  final String? error;
  final bool cancelled;

  UpgradeOutcome toOutcome() => UpgradeOutcome(
    ok
        ? UpgradeResult.ok
        : cancelled
        ? UpgradeResult.cancelled
        : UpgradeResult.rejected,
    tier: tier,
    expiresAt: expiresAt,
  );
}

/// Seam over the RevenueCat SDK so purchase flows are unit-testable.
abstract class RevenueCatPlatform {
  Future<void> configure({required String apiKey, required String appUserId});
  Future<List<RevenueCatPackage>> packages();
  Future<RevenueCatResult> purchasePackage(String identifier);
  Future<RevenueCatResult> restore();
  Future<RevenueCatResult> customerInfo();
}

/// RevenueCat purchase/entitlement service.
class RevenueCatBilling {
  RevenueCatBilling({
    RevenueCatPlatform? platform,
    String? Function()? uid,
    bool? testStore,
  }) : _platform = platform ?? PurchasesRevenueCatPlatform(),
       _uid = uid ?? (() => null),
       _testStore = testStore ?? kRevenueCatTestStore;

  static RevenueCatBilling? _instance;
  static RevenueCatBilling get I => _instance ??= RevenueCatBilling();

  @visibleForTesting
  static set instanceForTest(RevenueCatBilling? value) => _instance = value;

  final RevenueCatPlatform _platform;
  final String? Function() _uid;
  final bool _testStore;

  bool _configured = false;
  String? _configuredFor;

  /// Set when the last purchase was granted by the local demo fallback rather
  /// than by the store. The UI must label it "Test mode — no charge".
  bool lastPurchaseWasDemo = false;

  /// True when this build talks to the RevenueCat Test Store.
  bool get usingTestStore => _testStore;

  /// The key this build configures.
  String get apiKey => usingTestStore
      ? kRevenueCatTestStoreKey.trim()
      : kRevenueCatGoogleKey.trim();

  /// True when a public SDK key was compiled in.
  bool get available => apiKey.isNotEmpty;

  /// Configure once per signed-in uid. Safe to call repeatedly.
  Future<bool> configure({String? uid}) async {
    if (!available) return false;
    final user = uid ?? _uid();
    if (user == null || user.trim().isEmpty) return false;
    if (_configured && _configuredFor == user) return true;
    try {
      await _platform.configure(apiKey: apiKey, appUserId: user);
      _configured = true;
      _configuredFor = user;
      return true;
    } catch (e) {
      Diag.swallow('revenuecat.configure', e);
      return false;
    }
  }

  /// Packages currently offered, in dashboard order.
  Future<List<RevenueCatPackage>> packages() async {
    if (!await configure()) return const [];
    try {
      return await _platform.packages();
    } catch (e) {
      Diag.swallow('revenuecat.packages', e);
      return const [];
    }
  }

  /// Buys [tier] by matching the Play product id from [kOvidPlayProducts].
  Future<UpgradeOutcome> buy(String tier) async {
    lastPurchaseWasDemo = false;
    if (!available) return const UpgradeOutcome(UpgradeResult.notAvailable);
    if (!await configure()) {
      return const UpgradeOutcome(UpgradeResult.rejected);
    }
    final productId = kOvidPlayProducts[tier];
    if (productId == null) {
      return const UpgradeOutcome(UpgradeResult.rejected);
    }
    try {
      final offered = await _platform.packages();
      final match = offered.where((p) => p.productId == productId).firstOrNull;
      if (match == null) {
        // Test Store without an offering yet: grant a clearly-labelled demo
        // entitlement so the paywall can be exercised end to end.
        if (usingTestStore) {
          lastPurchaseWasDemo = true;
          return UpgradeOutcome(UpgradeResult.ok, tier: tier);
        }
        return const UpgradeOutcome(UpgradeResult.notAvailable);
      }
      final result = await _platform.purchasePackage(match.identifier);
      return result.toOutcome();
    } catch (e) {
      Diag.swallow('revenuecat.buy', e);
      if (usingTestStore) {
        lastPurchaseWasDemo = true;
        return UpgradeOutcome(UpgradeResult.ok, tier: tier);
      }
      return const UpgradeOutcome(UpgradeResult.unknown);
    }
  }

  Future<UpgradeOutcome> restore() async {
    if (!available) return const UpgradeOutcome(UpgradeResult.notAvailable);
    if (!await configure()) {
      return const UpgradeOutcome(UpgradeResult.rejected);
    }
    try {
      return (await _platform.restore()).toOutcome();
    } catch (e) {
      Diag.swallow('revenuecat.restore', e);
      return const UpgradeOutcome(UpgradeResult.unknown);
    }
  }

  /// The tier the store currently grants, or null when unknown.
  Future<String?> currentTier() async {
    if (!await configure()) return null;
    try {
      final info = await _platform.customerInfo();
      return info.ok ? info.tier : null;
    } catch (e) {
      Diag.swallow('revenuecat.customer_info', e);
      return null;
    }
  }
}

/// Real SDK implementation. All plugin errors are caught by the service.
class PurchasesRevenueCatPlatform implements RevenueCatPlatform {
  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {
    await Purchases.setLogLevel(LogLevel.warn);
    final config = PurchasesConfiguration(apiKey)..appUserID = appUserId;
    await Purchases.configure(config);
  }

  @override
  Future<List<RevenueCatPackage>> packages() async {
    final offerings = await Purchases.getOfferings();
    final offering = offerings.current;
    if (offering == null) return const [];
    return [
      for (final package in offering.availablePackages)
        RevenueCatPackage(
          identifier: package.identifier,
          productId: package.storeProduct.identifier,
          title: package.storeProduct.title,
          priceString: package.storeProduct.priceString,
        ),
    ];
  }

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async {
    final offerings = await Purchases.getOfferings();
    final offering = offerings.current;
    final package = offering?.availablePackages
        .where((p) => p.identifier == identifier)
        .firstOrNull;
    if (package == null) {
      return const RevenueCatResult(
        ok: false,
        error: 'That plan is not on sale right now.',
      );
    }
    try {
      final result = await Purchases.purchase(PurchaseParams.package(package));
      return _fromCustomerInfo(result.customerInfo);
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        return const RevenueCatResult.cancelled();
      }
      return RevenueCatResult(ok: false, error: e.message);
    }
  }

  @override
  Future<RevenueCatResult> restore() async {
    try {
      return _fromCustomerInfo(await Purchases.restorePurchases());
    } on PlatformException catch (e) {
      return RevenueCatResult(ok: false, error: e.message);
    }
  }

  @override
  Future<RevenueCatResult> customerInfo() async {
    try {
      return _fromCustomerInfo(await Purchases.getCustomerInfo());
    } on PlatformException catch (e) {
      return RevenueCatResult(ok: false, error: e.message);
    }
  }

  RevenueCatResult _fromCustomerInfo(CustomerInfo info) {
    String? bestTier;
    DateTime? bestExpiry;
    for (final entry in kRevenueCatEntitlements.entries) {
      final active = info.entitlements.active[entry.value];
      if (active == null) continue;
      final expiry = DateTime.tryParse(active.expirationDate ?? '');
      if (bestTier == null ||
          _rank(entry.key) > _rank(bestTier) ||
          (bestExpiry != null &&
              expiry != null &&
              expiry.isAfter(bestExpiry))) {
        bestTier = entry.key;
        bestExpiry = expiry;
      }
    }
    return RevenueCatResult(
      ok: bestTier != null,
      tier: bestTier,
      expiresAt: bestExpiry,
    );
  }

  int _rank(String tier) => switch (tier) {
    '15x' => 3,
    '7x' => 2,
    '3x' => 1,
    _ => 0,
  };
}
