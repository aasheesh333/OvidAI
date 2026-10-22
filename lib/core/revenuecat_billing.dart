import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'diag.dart';
import 'firebase_service.dart';
import 'ovid_cloud_service.dart';
import 'play_billing.dart';
import 'state.dart';

/// RevenueCat is the purchase/entitlement layer required by the product spec.
///
/// The Google public SDK key is **injected at build time**:
/// `--dart-define=OVID_REVENUECAT_GOOGLE_KEY=goog_...`. There is no baked-in
/// default: a build without the define disables RevenueCat and falls back to
/// the existing server-verified Google Play flow ([PlayBillingService]), so a
/// purchase is still verified by Ovid before a plan unlocks.
///
/// Entitlement ids (RevenueCat dashboard) map 1:1 to Ovid tiers:
/// `go` → `3x`, `plus` → `7x`, `pro` → `15x`.
const String kRevenueCatGoogleKey = String.fromEnvironment(
  'OVID_REVENUECAT_GOOGLE_KEY',
);

/// Public SDK key for the RevenueCat **Test Store** app in the same project.
/// Test Store purchases never charge a card, so internal-testing builds can
/// exercise the whole paywall before Play subscriptions exist.
///
/// Injected with `--dart-define=OVID_REVENUECAT_TEST_STORE_KEY=test_...`.
/// There is no baked-in default: a Test Store build without the key still
/// keeps the local demo path (see [RevenueCatBilling.buy]), so the key is
/// never shipped in a release binary.
const String kRevenueCatTestStoreKey = String.fromEnvironment(
  'OVID_REVENUECAT_TEST_STORE_KEY',
);

/// The raw opt-in: `--dart-define=OVID_REVENUECAT_TEST_STORE=true`.
///
/// On its own this is not enough — [resolveRevenueCatConfig] also requires a
/// non-release build, so a release build can never be switched to the Test
/// Store (and its local demo grant) by a stray define.
const bool kRevenueCatTestStoreRequested = bool.fromEnvironment(
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

/// The RevenueCat configuration a build actually uses.
@immutable
class RevenueCatConfig {
  const RevenueCatConfig({
    this.apiKey = '',
    this.testStore = false,
    this.error,
  });

  /// The SDK key compiled into this build (`''` when none was injected).
  final String apiKey;

  /// True only for a non-release build that explicitly opted into the Test
  /// Store. Never true in a release build.
  final bool testStore;

  /// Why this build has no usable RevenueCat config, when it does not.
  final String? error;

  bool get available => apiKey.isNotEmpty;
}

/// Whether a local demo entitlement may be granted.
///
/// Both conditions are required:
/// * an explicit opt-in (`--dart-define=OVID_REVENUECAT_TEST_STORE=true`), and
/// * a non-release build. A release build must never take the demo path: one
///   define would otherwise hand out a free plan.
bool demoGrantAllowed({required bool releaseMode, required bool testStore}) =>
    testStore && !releaseMode;

/// Resolves the RevenueCat configuration for a build.
///
/// Release builds:
/// * always refuse the Test Store, even when the define is present;
/// * require `OVID_REVENUECAT_GOOGLE_KEY`. A release build cannot `assert`
///   (asserts are stripped), so this is the release-side assertion: without
///   the key RevenueCat stays off and [RevenueCatConfig.error] records why.
///
/// Debug/profile builds may opt into the Test Store. Without a Test Store key
/// they still get the labelled local demo (no server call, no charge).
RevenueCatConfig resolveRevenueCatConfig({
  required bool releaseMode,
  required bool testStoreRequested,
  required String googleKey,
  required String testStoreKey,
}) {
  final key = googleKey.trim();
  final testKey = testStoreKey.trim();
  if (releaseMode) {
    if (testStoreRequested) {
      // A demo path in a release build is a free-plan bug, not a feature.
      Diag.swallow(
        'revenuecat.config',
        'ignoring OVID_REVENUECAT_TEST_STORE in a release build',
      );
    }
    if (key.isEmpty) {
      Diag.swallow(
        'revenuecat.config',
        'OVID_REVENUECAT_GOOGLE_KEY is not set for this release build; '
            'RevenueCat is disabled and Google Play verification is used',
      );
      return const RevenueCatConfig(
        error:
            'OVID_REVENUECAT_GOOGLE_KEY is not set for this release build. '
            'RevenueCat is disabled; purchases go through Google Play '
            'server verification.',
      );
    }
    return RevenueCatConfig(apiKey: key);
  }
  if (testStoreRequested) {
    return RevenueCatConfig(
      apiKey: testKey,
      testStore: true,
      error: testKey.isEmpty
          ? 'OVID_REVENUECAT_TEST_STORE_KEY is not set; the Test Store demo '
                'grants locally.'
          : null,
    );
  }
  if (key.isEmpty) {
    return const RevenueCatConfig(
      error:
          'OVID_REVENUECAT_GOOGLE_KEY is not set; RevenueCat is disabled and '
          'purchases go through Google Play server verification.',
    );
  }
  return RevenueCatConfig(apiKey: key);
}

/// The configuration compiled into this build.
final RevenueCatConfig kRevenueCatConfig = resolveRevenueCatConfig(
  releaseMode: kReleaseMode,
  testStoreRequested: kRevenueCatTestStoreRequested,
  googleKey: kRevenueCatGoogleKey,
  testStoreKey: kRevenueCatTestStoreKey,
);

/// True when this build may talk to the RevenueCat Test Store (debug/profile
/// plus the explicit define only).
bool get kRevenueCatTestStore => kRevenueCatConfig.testStore;

// ── Server-confirmed plan tier ───────────────────────────────────────────────

String? _confirmedPlanTier;

/// The plan tier a source of truth named for the signed-in account in this
/// session, or null when nothing has been confirmed yet.
String? get confirmedPlanTier => _confirmedPlanTier;

/// Records the tier the server (or the store's entitlement list) named.
/// Unknown values clear the confirmation instead of guessing.
void confirmPlanTier(String? tier) {
  _confirmedPlanTier = tier == 'free' || (tier != null && isKnownOvidTier(tier))
      ? tier
      : null;
}

/// True only when [tier] is exactly the plan a server answer confirmed.
///
/// `AppState.ovidCloudTier` is seeded from SharedPreferences before any server
/// refresh (`state.dart:4789` `_loadOvidCloudTier`), so it is display-only: a
/// refund, a cancellation or an account switch leaves it stale. Paid UI must
/// gate on this instead of on the cached field.
// WIRED-BY: coordinator — lib/core/state.dart:4789 (`_loadOvidCloudTier`)
// restores `ovidCloudTier` from the cache with no server check. The gates that
// read `AppState.I.ovidCloudTier` (e.g. `v2_settings_routes.dart:201` CTA and
// `:209` currentPlanId, `auth_screen.dart:139`, `sidebar.dart:1080`) must call
// `isServerConfirmed(tier)` / `confirmedPlanTier` from this file once
// state.dart / those hosts are editable.
bool isServerConfirmed(String tier) => _confirmedPlanTier == tier;

@visibleForTesting
void resetConfirmedPlanTierForTest() => _confirmedPlanTier = null;

/// Re-reads the plan tier from the server (`/usage`, which is also the plan
/// catalog source) and records it.
///
/// Returns the server's answer, or null when the server could not be asked.
/// Null is never a confirmation: callers must not unlock on it.
Future<String?> refreshServerTier({Future<String?> Function()? fetch}) async {
  String? tier;
  try {
    tier = await (fetch ?? _fetchUsageTier)();
  } catch (e) {
    Diag.swallow('billing.refresh_server_tier', e);
    return null;
  }
  if (tier == null) return null;
  confirmPlanTier(tier);
  return tier;
}

Future<String?> _fetchUsageTier() async =>
    (await OvidCloudService.I.fetchUsage())?.tier;

/// Applies a completed purchase to the local state, server first.
///
/// The client's purchase outcome alone never unlocks a plan:
/// * [demo] is the debug/profile Test Store demo (no server is involved); it
///   unlocks locally and is refused in release builds.
/// * otherwise `/usage` must name the account's plan first.
///
/// Returns true when the plan is unlocked for this account.
Future<bool> applyPurchasedPlan(
  String tier, {
  bool demo = false,
  Future<String?> Function()? fetch,
}) async {
  if (demo) {
    if (!demoGrantAllowed(releaseMode: kReleaseMode, testStore: true)) {
      return false;
    }
    confirmPlanTier(tier);
    AppState.I.setOvidCloudTier(tier);
    return true;
  }
  final server = await refreshServerTier(fetch: fetch);
  if (server == null || server == 'free') return false;
  AppState.I.setOvidCloudTier(server);
  return true;
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
class RevenueCatBilling with WidgetsBindingObserver {
  RevenueCatBilling({
    RevenueCatPlatform? platform,
    String? Function()? uid,
    RevenueCatConfig? config,
    bool? testStore,
    bool? releaseMode,
    void Function(String tier)? applyTier,
  }) : _platform = platform ?? PurchasesRevenueCatPlatform(),
       _uid = uid ?? (() => FirebaseService.I.uid),
       _releaseMode = releaseMode ?? kReleaseMode,
       _applyTier = applyTier ?? _applyTierToAppState,
       _config =
           config ??
           resolveRevenueCatConfig(
             releaseMode: releaseMode ?? kReleaseMode,
             testStoreRequested: testStore ?? kRevenueCatTestStoreRequested,
             googleKey: kRevenueCatGoogleKey,
             testStoreKey: kRevenueCatTestStoreKey,
           );

  static RevenueCatBilling? _instance;
  static RevenueCatBilling get I => _instance ??= RevenueCatBilling();

  @visibleForTesting
  static set instanceForTest(RevenueCatBilling? value) => _instance = value;

  static void _applyTierToAppState(String tier) =>
      AppState.I.setOvidCloudTier(tier);

  final RevenueCatPlatform _platform;
  final String? Function() _uid;
  final RevenueCatConfig _config;
  final bool _releaseMode;
  final void Function(String tier) _applyTier;

  bool _configured = false;
  String? _configuredFor;
  bool _started = false;
  bool _observerAttached = false;

  /// Set when the last purchase was granted by the local demo fallback rather
  /// than by the store. The UI must label it "Test mode — no charge".
  bool lastPurchaseWasDemo = false;

  /// Why the last [buy] could not start, when it could not. The UI shows this
  /// instead of the generic "not available" copy (for example a yearly
  /// package that the current offering does not contain).
  String? lastPurchaseError;

  /// True when this build talks to the RevenueCat Test Store.
  bool get usingTestStore => _config.testStore && !_releaseMode;

  /// A debug/profile Test Store build with no SDK key: the paywall is exercised
  /// with the labelled local demo and nothing is ever queried.
  bool get _demoOnly => usingTestStore && _config.apiKey.isEmpty;

  /// The key this build configures.
  String get apiKey => _config.apiKey;

  /// True when a purchase can be attempted: a real SDK key or the local demo.
  bool get available => apiKey.isNotEmpty || _demoOnly;

  /// Why this build has no usable RevenueCat config, when it does not.
  String? get configError => _config.error;

  /// Call once at launch: reconciles the cached plan with the store now and
  /// keeps it in step on every app resume.
  ///
  /// Safe to call repeatedly and safe when RevenueCat is not configured.
  void start() {
    if (!available) return;
    _attachLifecycle();
    if (_started) return;
    _started = true;
    unawaited(reconcile());
  }

  void _attachLifecycle() {
    if (_observerAttached) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _observerAttached = true;
    } catch (e) {
      // No widget binding (unit tests): resume wiring is simply absent.
      Diag.swallow('revenuecat.lifecycle', e);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(reconcile());
  }

  /// Configure once per signed-in uid. Safe to call repeatedly.
  Future<bool> configure({String? uid}) async {
    final error = _config.error;
    if (error != null) Diag.swallow('revenuecat.config', error);
    if (_demoOnly) return false;
    if (!available) return false;
    final user = uid ?? _uid();
    if (user == null || user.trim().isEmpty) return false;
    if (_configured && _configuredFor == user) return true;
    try {
      await _platform.configure(apiKey: apiKey, appUserId: user);
      _configured = true;
      _configuredFor = user;
      _attachLifecycle();
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

  /// Buys [tier] for [period] by matching the Play product id from
  /// [kOvidPlayProductIds].
  ///
  /// A yearly request never falls back to the monthly package: buying the
  /// monthly SKU for a yearly selection would charge the wrong period. A
  /// missing yearly package is reported as [UpgradeResult.notAvailable] with
  /// [lastPurchaseError] explaining why.
  Future<UpgradeOutcome> buy(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) async {
    lastPurchaseWasDemo = false;
    lastPurchaseError = null;
    final productId = ovidPlayProductId(tier, period);
    if (productId == null) {
      // A tier that is not an Ovid plan is a caller bug, not a missing store
      // product; keep the historical "rejected" answer for it.
      if (!kOvidPlayProducts.containsKey(tier)) {
        return const UpgradeOutcome(UpgradeResult.rejected);
      }
      lastPurchaseError = _periodUnavailableMessage(period);
      return const UpgradeOutcome(UpgradeResult.notAvailable);
    }
    final demoAllowed = demoGrantAllowed(
      releaseMode: _releaseMode,
      testStore: usingTestStore,
    );
    if (_demoOnly) {
      // Debug/profile Test Store build with no key: nothing can be queried,
      // so the documented demo path runs and the UI labels it "Test mode".
      lastPurchaseWasDemo = true;
      return UpgradeOutcome(UpgradeResult.ok, tier: tier);
    }
    if (!available) {
      lastPurchaseError = _periodUnavailableMessage(period);
      return const UpgradeOutcome(UpgradeResult.notAvailable);
    }
    if (!await configure()) {
      return const UpgradeOutcome(UpgradeResult.rejected);
    }
    try {
      final offered = await _platform.packages();
      final match = _packageFor(offered, productId, tier: tier, period: period);
      if (match == null) {
        lastPurchaseError = _periodUnavailableMessage(period);
        // Test Store without a monthly offering yet: grant a clearly-labelled
        // demo entitlement so the paywall can be exercised end to end. Never
        // in a release build (demoAllowed is false there), and never for a
        // yearly selection — that would hide a missing yearly package.
        if (demoAllowed && period == OvidBillingPeriod.monthly) {
          lastPurchaseWasDemo = true;
          lastPurchaseError = null;
          return UpgradeOutcome(UpgradeResult.ok, tier: tier);
        }
        return const UpgradeOutcome(UpgradeResult.notAvailable);
      }
      final result = await _platform.purchasePackage(match.identifier);
      return result.toOutcome();
    } catch (e) {
      Diag.swallow('revenuecat.buy', e);
      if (demoAllowed) {
        lastPurchaseWasDemo = true;
        return UpgradeOutcome(UpgradeResult.ok, tier: tier);
      }
      return const UpgradeOutcome(UpgradeResult.unknown);
    }
  }

  /// The package to purchase for [productId].
  ///
  /// The offering is matched by product id first. Only a *monthly* request may
  /// use RevenueCat's conventional monthly package when the product id is not
  /// found, and never when that package belongs to a different Ovid tier. A
  /// yearly request never falls back.
  static RevenueCatPackage? _packageFor(
    List<RevenueCatPackage> offered,
    String productId, {
    required String tier,
    required OvidBillingPeriod period,
  }) {
    final exact = offered.where((p) => p.productId == productId).firstOrNull;
    if (exact != null) return exact;
    if (period == OvidBillingPeriod.yearly) return null;
    return offered.where((p) {
      if (p.identifier != r'$rc_monthly' && p.identifier != 'monthly') {
        return false;
      }
      // A legacy monthly product id is acceptable; a known product that
      // belongs to another tier is not (that would buy the wrong plan).
      final owner = ovidTierForProduct(p.productId);
      return owner == null || owner == tier;
    }).firstOrNull;
  }

  static String _periodUnavailableMessage(OvidBillingPeriod period) =>
      period == OvidBillingPeriod.yearly
      ? 'Yearly billing is not available for this plan yet.'
      : 'Monthly billing is not available for this plan right now.';

  Future<UpgradeOutcome> restore() async {
    lastPurchaseWasDemo = false;
    if (_demoOnly) {
      // The demo grants on buy only; there is no store purchase to restore.
      return const UpgradeOutcome(UpgradeResult.nothingToRestore);
    }
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

  /// Reconciles the local plan with the store's entitlements.
  ///
  /// Refunds, cancellations and expiries remove the entitlement, so the cached
  /// tier would otherwise keep a paid plan unlocked forever. Only a
  /// *downgrade* is applied here: an active entitlement never unlocks by
  /// itself — the server still has to name the plan
  /// ([refreshServerTier] / [applyPurchasedPlan]).
  ///
  /// Returns the store's tier (`'free'` when the entitlement is gone), or null
  /// when the store could not be asked. An unreachable store or an SDK error
  /// changes nothing: an offline launch must not wipe a paying user's plan.
  Future<String?> reconcile() async {
    if (_demoOnly) return null;
    if (!available) return null;
    if (!await configure()) return null;
    try {
      final info = await _platform.customerInfo();
      // ok=false with an error means "could not ask", not "no entitlement".
      if (!info.ok && info.error != null) return null;
      final tier = info.ok ? (info.tier ?? 'free') : 'free';
      if (tier == 'free') {
        confirmPlanTier('free');
        _applyTier('free');
      }
      return tier;
    } catch (e) {
      Diag.swallow('revenuecat.reconcile', e);
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
