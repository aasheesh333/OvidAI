import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart'
    show ReplacementMode;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'diag.dart';
import 'billing_products.dart';
import 'billing_uid.dart';
import 'ovid_cloud_service.dart';

export 'billing_products.dart';


/// Billing period for a Play product ID, or null when it is not an Ovid plan.
OvidBillingPeriod? ovidPeriodForProduct(String productId) {
  for (final entry in kOvidPlayProductIds.entries) {
    if (entry.value == productId) return entry.key.$2;
  }
  return null;
}

/// Thin seam over `in_app_purchase` so purchase flows are testable with a
/// fake store.
abstract class BillingPlatform {
  Future<bool> isAvailable();
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids);

  /// Starts the Play purchase sheet. [replacing] is the currently owned plan
  /// when upgrading (prorated replacement on Google Play).
  Future<bool> buy({
    required ProductDetails product,
    required String accountId,
    PurchaseDetails? replacing,
  });

  /// Acknowledges a purchase. Call ONLY after the server verified it.
  Future<void> completePurchase(PurchaseDetails purchase);
  Future<void> restorePurchases({String? accountId});
}

class InAppPurchaseBillingPlatform implements BillingPlatform {
  InAppPurchase get _iap => InAppPurchase.instance;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) =>
      _iap.queryProductDetails(ids);

  @override
  Future<bool> buy({
    required ProductDetails product,
    required String accountId,
    PurchaseDetails? replacing,
  }) {
    final PurchaseParam param = product is GooglePlayProductDetails
        ? GooglePlayPurchaseParam(
            productDetails: product,
            applicationUserName: accountId,
            offerToken: product.offerToken,
            changeSubscriptionParam: replacing is GooglePlayPurchaseDetails
                ? ChangeSubscriptionParam(
                    oldPurchaseDetails: replacing,
                    replacementMode: ReplacementMode.chargeProratedPrice,
                  )
                : null,
          )
        : PurchaseParam(
            productDetails: product,
            applicationUserName: accountId,
          );
    // Subscriptions are bought with buyNonConsumable on every platform.
    return _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _iap.completePurchase(purchase);

  @override
  Future<void> restorePurchases({String? accountId}) =>
      _iap.restorePurchases(applicationUserName: accountId);
}

typedef PlayPurchaseVerifier =
    Future<PlayVerifyOutcome> Function({
      required String productId,
      required String purchaseToken,
      required String packageName,
    });

/// Google Play subscription flow for Ovid Cloud plans (F-009).
///
/// Purchase → server `/billing/verify` → tier set → acknowledge. A purchase
/// is never acknowledged before the server confirms it; unacknowledged Play
/// purchases are refunded by Google after 3 days, and they are re-delivered
/// (and re-verified) on the next [ensureLoaded] / [restore].
class PlayBillingService extends ChangeNotifier {
  PlayBillingService({
    BillingPlatform? platform,
    PlayPurchaseVerifier? verifier,
    String? Function()? uid,
    this.purchaseTimeout = const Duration(minutes: 10),
  }) : _platform = platform ?? InAppPurchaseBillingPlatform(),
       _verifier = verifier ?? OvidCloudService.I.verifyPlayPurchase,
       _uid = uid ?? ovidBillingUid;

  static PlayBillingService? _instance;
  static PlayBillingService get I => _instance ??= PlayBillingService();

  @visibleForTesting
  static set instanceForTest(PlayBillingService? value) => _instance = value;

  final BillingPlatform _platform;
  final PlayPurchaseVerifier _verifier;
  final String? Function() _uid;

  /// Upper bound on one purchase sheet (SH-014): if Play never delivers a
  /// result for the product (sheet killed, Play Store force-stopped), the
  /// waiter resolves `unknown` and the plan's button works again.
  final Duration purchaseTimeout;

  /// The uid whose purchases [_owned] / [_ownedTier] describe (SH-013).
  String? _loadedFor;

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  Future<void>? _loading;
  bool _available = false;
  bool _loaded = false;
  final Map<(String, OvidBillingPeriod), ProductDetails> _products = {};
  PurchaseDetails? _owned;
  String? _ownedTier;
  DateTime? _expiresAt;
  bool? _autoRenewing;
  final Map<String, Completer<UpgradeOutcome>> _waiting = {};
  Completer<UpgradeOutcome>? _restoreWaiter;

  /// Why the last [buy] could not start, when it could not. The UI shows this
  /// instead of the generic "not available" copy (e.g. a yearly product that
  /// Play does not sell yet).
  String? lastPurchaseError;

  /// Google Play is reachable and the plan products were found.
  bool get available => _available && _products.isNotEmpty;
  bool get loaded => _loaded;

  /// Localised Play product (price in the user's currency) for [tier] and
  /// [period]. Defaults to monthly for callers that predate yearly billing.
  ProductDetails? productFor(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) => _products[(tier, period)];

  /// True when Play returned a product for [tier] in [period].
  bool hasProduct(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) => _products.containsKey((tier, period));

  /// The verified, owned plan purchase on this device, if any.
  String? get ownedTier => _ownedTier;
  String? get ownedProductId => _owned?.productID;
  DateTime? get expiresAt => _expiresAt;
  bool? get autoRenewing => _autoRenewing;

  /// "/ month" style suffix from the Play base plan's billing period.
  String periodLabel(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) {
    final product = _products[(tier, period)];
    if (product is GooglePlayProductDetails) {
      final index = product.subscriptionIndex;
      final offers = product.productDetails.subscriptionOfferDetails;
      if (index != null && offers != null && index < offers.length) {
        final phases = offers[index].pricingPhases;
        if (phases.isNotEmpty) {
          return billingPeriodLabel(phases.last.billingPeriod);
        }
      }
    }
    return 'month';
  }

  /// Maps an ISO-8601 period (P1M, P1Y, P1W, P3M) to copy.
  static String billingPeriodLabel(String iso) => switch (iso) {
    'P1W' => 'week',
    'P1M' => 'month',
    'P3M' => '3 months',
    'P6M' => '6 months',
    'P1Y' => 'year',
    _ => 'period',
  };

  /// Connects to Play once, loads products and re-checks owned purchases
  /// (picks up purchases that were paid but not yet verified/acknowledged).
  Future<void> ensureLoaded() {
    // A different account than the one loaded: forget the previous one's
    // plan and re-read this account's purchases (SH-013).
    if (_loadedFor != _uid()) resetForAccount();
    return _loading ??= _load();
  }

  /// Clears every per-account fact (owned plan, expiry, renewal, pending
  /// purchase/restore waiters) so account B never sees account A's plan or
  /// "Manage subscription". The Play connection and product catalogue are
  /// device-wide and kept. The next [ensureLoaded] re-reads B's purchases.
  void resetForAccount() {
    final hadState = _owned != null || _ownedTier != null || _expiresAt != null;
    _owned = null;
    _ownedTier = null;
    _expiresAt = null;
    _autoRenewing = null;
    _loading = null;
    _loadedFor = null;
    for (final waiter in _waiting.values) {
      if (!waiter.isCompleted) {
        waiter.complete(const UpgradeOutcome(UpgradeResult.rejected));
      }
    }
    _waiting.clear();
    _finishRestore(const UpgradeOutcome(UpgradeResult.rejected));
    if (hadState) notifyListeners();
  }

  Future<void> _load() async {
    _loadedFor = _uid();
    try {
      // Inside the try: without the platform plugin (tests, unsupported
      // devices) the stream getter throws; that simply means no Play.
      _subscription ??= _platform.purchaseStream.listen(
        _onPurchases,
        onError: (Object e) => Diag.swallow('play_billing.stream', e),
      );
      _available = await _platform.isAvailable();
      if (_available) {
        final response = await _platform.queryProductDetails(
          kOvidPlayProductIds.values.toSet(),
        );
        _products
          ..clear()
          ..addAll(_pickBasePlans(response.productDetails));
      }
    } catch (e) {
      Diag.swallow('play_billing.load', e);
      _available = false;
    } finally {
      _loaded = true;
      notifyListeners();
    }
    if (_available) {
      final uid = _uid();
      try {
        await _platform.restorePurchases(
          accountId: uid == null ? null : ovidPlayAccountId(uid),
        );
      } catch (e) {
        Diag.swallow('play_billing.restore_on_load', e);
      }
    }
  }

  /// Prefer each subscription's base plan (no offer ID, i.e. no trial/promo).
  static Map<(String, OvidBillingPeriod), ProductDetails> _pickBasePlans(
    List<ProductDetails> all,
  ) {
    final out = <(String, OvidBillingPeriod), ProductDetails>{};
    for (final product in all) {
      final tier = ovidTierForProduct(product.id);
      final period = ovidPeriodForProduct(product.id);
      if (tier == null || period == null) continue;
      final key = (tier, period);
      final isBase =
          product is! GooglePlayProductDetails ||
          product.subscriptionIndex == null ||
          product
                  .productDetails
                  .subscriptionOfferDetails?[product.subscriptionIndex!]
                  .offerId ==
              null;
      if (!out.containsKey(key) || isBase) out[key] = product;
    }
    return out;
  }

  /// Buys (or upgrades to) [tier] for [period]. Completes after the server
  /// verified the purchase, or with the reason it did not.
  ///
  /// A yearly request never falls back to the monthly product: that would
  /// charge the wrong period at the wrong price.
  Future<UpgradeOutcome> buy(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) async {
    lastPurchaseError = null;
    await ensureLoaded();
    final configured = ovidPlayProductId(tier, period);
    if (configured == null) {
      lastPurchaseError = _periodUnavailableMessage(period);
      return const UpgradeOutcome(UpgradeResult.notAvailable);
    }
    final product = _products[(tier, period)];
    if (!_available || product == null) {
      lastPurchaseError = _periodUnavailableMessage(period);
      return const UpgradeOutcome(UpgradeResult.notAvailable);
    }
    final uid = _uid();
    if (uid == null) return const UpgradeOutcome(UpgradeResult.rejected);
    final existing = _waiting[product.id];
    if (existing != null) return existing.future;
    final waiter = Completer<UpgradeOutcome>();
    _waiting[product.id] = waiter;
    try {
      final started = await _platform.buy(
        product: product,
        accountId: ovidPlayAccountId(uid),
        replacing: _owned != null && _owned!.productID != product.id
            ? _owned
            : null,
      );
      if (!started) {
        _resolve(product.id, const UpgradeOutcome(UpgradeResult.unknown));
      }
    } catch (e) {
      Diag.swallow('play_billing.buy', e);
      _resolve(product.id, UpgradeOutcome(_storeError('$e')));
    }
    return waiter.future.timeout(
      purchaseTimeout,
      onTimeout: () {
        if (identical(_waiting[product.id], waiter)) {
          _waiting.remove(product.id);
        }
        return const UpgradeOutcome(UpgradeResult.unknown);
      },
    );
  }

  /// The honest reason a period cannot be bought here.
  static String _periodUnavailableMessage(OvidBillingPeriod period) =>
      period == OvidBillingPeriod.yearly
      ? 'Yearly billing is not available for this plan yet.'
      : 'Monthly billing is not available for this plan right now.';

  /// App resume: silently re-reads owned purchases so a payment that could
  /// not be confirmed earlier ([UpgradeResult.confirming]) is re-verified
  /// before Play's 3-day refund window closes. No-op until loaded.
  Future<void> recheckOnResume() async {
    if (!_loaded || !_available) return;
    final uid = _uid();
    if (uid == null || uid != _loadedFor) return;
    try {
      await _platform.restorePurchases(accountId: ovidPlayAccountId(uid));
    } catch (e) {
      Diag.swallow('play_billing.recheck', e);
    }
  }

  /// Abandons a purchase sheet that Play never answered (the sheet's Cancel
  /// after ~30 s). A late Play delivery is still verified by the stream
  /// listener and re-verified on the next launch.
  void abandonPurchase(
    String tier, {
    OvidBillingPeriod period = OvidBillingPeriod.monthly,
  }) {
    final product = _products[(tier, period)];
    if (product == null) return;
    _resolve(product.id, const UpgradeOutcome(UpgradeResult.unknown));
  }

  /// "Restore purchases": re-reads owned subscriptions from Play and
  /// re-verifies them with the server.
  Future<UpgradeOutcome> restore() async {
    await ensureLoaded();
    if (!_available) return const UpgradeOutcome(UpgradeResult.notAvailable);
    final uid = _uid();
    if (uid == null) return const UpgradeOutcome(UpgradeResult.rejected);
    final waiter = _restoreWaiter ??= Completer<UpgradeOutcome>();
    try {
      await _platform.restorePurchases(accountId: ovidPlayAccountId(uid));
    } catch (e) {
      Diag.swallow('play_billing.restore', e);
      _finishRestore(UpgradeOutcome(_storeError('$e')));
    }
    return waiter.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        _restoreWaiter = null;
        return const UpgradeOutcome(UpgradeResult.offline);
      },
    );
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    final restoreWaiter = _restoreWaiter;
    UpgradeOutcome? restoreResult;
    for (final purchase in purchases) {
      final tier = ovidTierForProduct(purchase.productID);
      if (tier == null) continue;
      final outcome = await _handle(purchase, tier);
      if (outcome == null) continue;
      _resolve(purchase.productID, outcome);
      if (restoreResult == null || _rank(outcome) > _rank(restoreResult)) {
        restoreResult = outcome;
      }
    }
    if (restoreWaiter != null &&
        identical(restoreWaiter, _restoreWaiter) &&
        purchases.every(
          (p) =>
              p.status == PurchaseStatus.restored ||
              // An unacknowledged purchase is re-delivered as `purchased`
              // during a restore. It has been verified above, so the restore
              // succeeded rather than "found nothing".
              p.status == PurchaseStatus.purchased ||
              ovidTierForProduct(p.productID) == null,
        )) {
      _finishRestore(
        restoreResult ?? const UpgradeOutcome(UpgradeResult.nothingToRestore),
      );
    }
  }

  static int _rank(UpgradeOutcome o) => switch (o.result) {
    UpgradeResult.ok => 3,
    UpgradeResult.pending => 2,
    UpgradeResult.nothingToRestore => 0,
    _ => 1,
  };

  Future<UpgradeOutcome?> _handle(PurchaseDetails purchase, String tier) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        notifyListeners();
        return const UpgradeOutcome(UpgradeResult.pending);
      case PurchaseStatus.canceled:
        return const UpgradeOutcome(UpgradeResult.cancelled);
      case PurchaseStatus.error:
        return UpgradeOutcome(
          _storeError('${purchase.error?.code} ${purchase.error?.message}'),
        );
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        final token = purchase.verificationData.serverVerificationData;
        if (token.isEmpty) return const UpgradeOutcome(UpgradeResult.unknown);
        final verdict = await _verifier(
          productId: purchase.productID,
          purchaseToken: token,
          packageName: kOvidPlayPackage,
        );
        if (verdict.result == UpgradeResult.ok && verdict.acknowledge) {
          // Server verified and set the tier: now (and only now) acknowledge.
          if (purchase.pendingCompletePurchase) {
            try {
              await _platform.completePurchase(purchase);
            } catch (e) {
              // Re-delivered and re-verified (idempotent) on next launch.
              Diag.swallow('play_billing.acknowledge', e);
            }
          }
          _owned = purchase;
          _ownedTier = verdict.tier ?? tier;
          _expiresAt = verdict.expiresAt;
          _autoRenewing = verdict.autoRenewing;
          notifyListeners();
          return UpgradeOutcome(
            UpgradeResult.ok,
            tier: verdict.tier ?? tier,
            expiresAt: verdict.expiresAt,
            autoRenewing: verdict.autoRenewing,
          );
        }
        if (verdict.result == UpgradeResult.ok) {
          // Verified but not active (expired / replaced): nothing to grant.
          return UpgradeOutcome(UpgradeResult.rejected, tier: verdict.tier);
        }
        // Play took the money but Ovid could not confirm it (verify route
        // missing, server down, offline). The purchase stays unacknowledged:
        // Play re-delivers it and ensureLoaded/restore re-verifies it. Never
        // tell a paying user "Nothing was charged" (SH-002).
        if (verdict.result == UpgradeResult.notAvailable ||
            verdict.result == UpgradeResult.unknown ||
            verdict.result == UpgradeResult.offline) {
          return UpgradeOutcome(UpgradeResult.confirming, tier: tier);
        }
        return UpgradeOutcome(verdict.result, tier: verdict.tier);
    }
  }

  void _resolve(String productId, UpgradeOutcome outcome) {
    final waiter = _waiting.remove(productId);
    if (waiter != null && !waiter.isCompleted) waiter.complete(outcome);
  }

  void _finishRestore(UpgradeOutcome outcome) {
    final waiter = _restoreWaiter;
    _restoreWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(outcome);
  }

  static UpgradeResult _storeError(String text) {
    final t = text.toLowerCase();
    if (t.contains('network') ||
        t.contains('serviceunavailable') ||
        t.contains('service_unavailable') ||
        t.contains('timeout')) {
      return UpgradeResult.offline;
    }
    if (t.contains('billingunavailable') || t.contains('featurenotsupported')) {
      return UpgradeResult.notAvailable;
    }
    return UpgradeResult.unknown;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
