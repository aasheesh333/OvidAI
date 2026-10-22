import 'package:flutter/material.dart';

import '../../../core/billing_products.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'purchase_banner.dart';
import 'step_progress.dart';

// TODO(l10n): move paywall copy to the ARB files.

enum V2Currency { usd, inr }

/// The billing period the paywall is quoting and selling.
enum V2PaywallPeriod { monthly, yearly }

/// The screen predates the Plan & billing enum. Keeping the alias means a
/// caller that already uses `V2BillingPeriod` can pass it here unchanged.
typedef V2BillingPeriod = V2PaywallPeriod;

/// One purchase request from a plan card.
///
/// [productId] is resolved from the billing catalogue, never invented by the
/// UI. A period with no configured product cannot construct this object, so a
/// yearly selection can never fall through to the monthly SKU.
@immutable
class V2PaywallPurchase {
  const V2PaywallPurchase({
    required this.planId,
    required this.tier,
    required this.period,
    required this.productId,
  });

  /// The card id (`free`, `go`, `plus`, `pro`).
  final String planId;

  /// The billing tier (`3x`, `7x`, `15x`).
  final String tier;
  final V2PaywallPeriod period;
  final String productId;

  bool get yearly => period == V2PaywallPeriod.yearly;
}

/// What a real restore call returned.
enum V2PaywallRestoreResult {
  /// The store found an active subscription for this account.
  restored,

  /// The store answered and there is no active subscription.
  nothingToRestore,

  /// The store could not be asked or refused the request.
  failed,
}

@immutable
class V2PlanOption {
  const V2PlanOption({
    required this.id,
    required this.name,
    required this.priceUsd,
    required this.priceInr,
    required this.storageGb,
    this.priceUsdYearly,
    this.priceInrYearly,
    this.autoOnly = false,
    this.features = const [],
    this.storePriceMonthly,
    this.storePriceYearly,
    this.storeCurrency,
    this.storeMonthlyAvailable,
    this.storeYearlyAvailable,
  });

  final String id;
  final String name;

  /// Monthly price. The yearly price is a separate, explicitly supplied
  /// number: multiplying a monthly price by 12 (or even 10) in the UI would
  /// invent an amount the store never charges.
  final int priceUsd;
  final int priceInr;

  /// Yearly price. Null means the plan is not sold yearly; the card says so
  /// and disables its CTA instead of showing a made-up figure.
  final int? priceUsdYearly;
  final int? priceInrYearly;

  final int storageGb;
  final bool autoOnly;

  /// At most three are shown; the card is a comparison, not a feature list.
  final List<String> features;

  /// The store's own localised price for each period, when the store was
  /// queried and sells it. Displayed instead of the canonical table so the
  /// amount on screen is the amount Google Play charges.
  final String? storePriceMonthly;
  final String? storePriceYearly;

  /// ISO currency of [storePriceMonthly] / [storePriceYearly] (`USD`, `INR`).
  /// The price string already carries its symbol; this records which currency
  /// the store quoted for diagnostics.
  final String? storeCurrency;

  /// Whether the store sells the period. Null means "not queried yet"; false
  /// disables the CTA with a real reason instead of attempting a missing SKU.
  final bool? storeMonthlyAvailable;
  final bool? storeYearlyAvailable;

  /// Maps a server tier id or a display name onto the canonical card id.
  static String canonicalIdFor(String id) {
    final key = id.trim().toLowerCase();
    return switch (key) {
      'free' || 'ovid free' => 'free',
      '3x' || 'go' || 'ovid go' => 'go',
      '7x' || 'plus' || 'ovid plus' => 'plus',
      '15x' || 'pro' || 'ovid pro' => 'pro',
      _ => key,
    };
  }

  String get canonicalId => canonicalIdFor(id);

  /// The Free tier is the only plan that is not billed.
  bool get isFree => canonicalId == 'free';

  /// RevenueCat / server tier id for this card.
  String get tier => switch (canonicalId) {
    'go' => '3x',
    'plus' => '7x',
    'pro' => '15x',
    _ => canonicalId,
  };

  /// The price for [period], or null when there is no real price. Free is a
  /// real zero; a paid plan with no configured price is not.
  int? amountFor(V2Currency currency, V2PaywallPeriod period) {
    if (isFree) return 0;
    final amount = switch (period) {
      V2PaywallPeriod.monthly =>
        currency == V2Currency.inr ? priceInr : priceUsd,
      V2PaywallPeriod.yearly =>
        currency == V2Currency.inr ? priceInrYearly : priceUsdYearly,
    };
    return amount == null || amount <= 0 ? null : amount;
  }

  bool hasPrice(V2Currency currency, V2PaywallPeriod period) =>
      amountFor(currency, period) != null;

  /// The store's price for [period], or null when the store was not queried
  /// or does not sell it.
  ///
  /// The store string already carries its own currency (Play localises it), so
  /// it wins over the currency toggle: the card must show the amount Google
  /// Play will actually charge, not a converted guess.
  String? storePriceFor(V2Currency currency, V2PaywallPeriod period) {
    final price = period == V2PaywallPeriod.yearly
        ? storePriceYearly
        : storePriceMonthly;
    if (price == null || price.trim().isEmpty) return null;
    return price;
  }

  /// null = the store has not been queried; false = it does not sell [period].
  bool? storeAvailableFor(V2PaywallPeriod period) => period == V2PaywallPeriod.yearly
      ? storeYearlyAvailable
      : storeMonthlyAvailable;

  /// A copy carrying what the store reported for this build.
  V2PlanOption withStore({
    String? monthlyPrice,
    String? yearlyPrice,
    String? currency,
    bool? monthlyAvailable,
    bool? yearlyAvailable,
  }) => V2PlanOption(
    id: id,
    name: name,
    priceUsd: priceUsd,
    priceInr: priceInr,
    priceUsdYearly: priceUsdYearly,
    priceInrYearly: priceInrYearly,
    storageGb: storageGb,
    autoOnly: autoOnly,
    features: features,
    storePriceMonthly: monthlyPrice,
    storePriceYearly: yearlyPrice,
    storeCurrency: currency,
    storeMonthlyAvailable: monthlyAvailable,
    storeYearlyAvailable: yearlyAvailable,
  );

  String priceFor(
    V2Currency currency, [
    V2PaywallPeriod period = V2PaywallPeriod.monthly,
  ]) {
    final store = storePriceFor(currency, period);
    if (store != null) return store;
    final amount = amountFor(currency, period);
    if (amount == null) return '—';
    return currency == V2Currency.inr
        ? '₹${_groupInr(amount)}'
        : '\$${_groupDigits(amount)}';
  }

  /// `/ month`, `/ year`, or `forever` for Free.
  String periodSuffix(V2PaywallPeriod period) {
    if (isFree) return 'forever';
    return period == V2PaywallPeriod.yearly ? '/ year' : '/ month';
  }

  /// Spoken form of [periodSuffix], for a screen reader.
  String periodPhrase(V2PaywallPeriod period) {
    if (isFree) return 'forever';
    return period == V2PaywallPeriod.yearly ? 'per year' : 'per month';
  }

  /// The Play product for [period], or null when that period is not sold.
  /// Free has no product by design.
  String? productIdFor(V2PaywallPeriod period) {
    if (isFree) return null;
    return ovidPlayProductId(
      tier,
      period == V2PaywallPeriod.yearly
          ? OvidBillingPeriod.yearly
          : OvidBillingPeriod.monthly,
    );
  }

  /// `Ovid Plus` → `Plus`, so a card CTA stays two words.
  String get shortName => name.replaceFirst(RegExp(r'^Ovid\s+'), '');

  /// The canonical product table: Free and Go only run the Auto model, Plus
  /// and Pro unlock manual model choice.
  String get modelAccessLabel => autoOnly ? 'Auto only' : 'Auto + manual';

  /// Monthly suffix, kept for callers that predate the period toggle.
  String get pricePeriod => periodSuffix(V2PaywallPeriod.monthly);
}

@immutable
class V2PaywallData {
  const V2PaywallData({
    this.plans = const [
      V2PlanOption(
        id: 'free',
        name: 'Ovid Free',
        priceUsd: 0,
        priceInr: 0,
        priceUsdYearly: 0,
        priceInrYearly: 0,
        storageGb: 3,
        autoOnly: true,
        features: ['3 GB storage', '50M tokens a day', 'Manual models locked'],
      ),
      V2PlanOption(
        id: 'go',
        name: 'Ovid Go',
        priceUsd: 5,
        priceInr: 499,
        priceUsdYearly: 50,
        priceInrYearly: 4990,
        storageGb: 5,
        autoOnly: true,
        features: [
          '5 GB storage',
          '5 custom connectors',
          'Manual models locked',
        ],
      ),
      V2PlanOption(
        id: 'plus',
        name: 'Ovid Plus',
        priceUsd: 18,
        priceInr: 1799,
        priceUsdYearly: 180,
        priceInrYearly: 17990,
        storageGb: 15,
        features: ['15 GB storage', 'Manual models', '20 custom connectors'],
      ),
      V2PlanOption(
        id: 'pro',
        name: 'Ovid Pro',
        priceUsd: 99,
        priceInr: 9999,
        priceUsdYearly: 990,
        priceInrYearly: 99990,
        storageGb: 75,
        features: ['75 GB storage', 'Manual models', '20 custom connectors'],
      ),
    ],
    this.selectedPlanId = 'plus',
    this.currency = V2Currency.usd,
    this.period = V2PaywallPeriod.monthly,
    this.currentPlanId,
    this.loading = false,
    this.purchasing = false,
    this.error,
    this.purchaseStatus,
    this.purchaseDetail,
    this.testModeNote,
    this.checkoutBlockedReason,
    this.trialDays = 0,
  });

  final List<V2PlanOption> plans;
  final String selectedPlanId;
  final V2Currency currency;
  final V2PaywallPeriod period;

  /// The plan the account already owns (`go`, `plus`, `pro`, or a server tier
  /// id). When set, the primary action becomes Manage instead of a purchase.
  final String? currentPlanId;

  final bool loading;
  final bool purchasing;
  final String? error;

  /// What the billing layer says happened, rendered by [V2PurchaseBanner].
  ///
  /// When null the banner is derived from [error] (failed) and
  /// [testModeNote] (test store), so existing hosts keep working.
  final V2PurchaseBannerStatus? purchaseStatus;

  /// Store-provided extra detail for [purchaseStatus], e.g. a failure reason.
  /// Never replaces the standard banner copy.
  final String? purchaseDetail;

  /// Legacy test-store note. Still honoured as the banner detail; new hosts
  /// should pass `purchaseStatus: V2PurchaseBannerStatus.testStore` instead.
  final String? testModeNote;

  /// A build-level reason every paid plan cannot be bought right now, even
  /// though the card has a product and a price.
  ///
  /// Set when the only available purchase path cannot be server-confirmed
  /// (a RevenueCat build with no webhook): the CTA is disabled and this reason
  /// is shown instead of starting a charge that would never unlock the plan.
  final String? checkoutBlockedReason;

  /// Length of the Play introductory offer, in days. Zero means no trial is
  /// configured, so the call to action must not promise one.
  final int trialDays;

  V2PlanOption? planFor(String? id) {
    if (id == null) return null;
    final canonical = V2PlanOption.canonicalIdFor(id);
    for (final plan in plans) {
      if (plan.canonicalId == canonical) return plan;
    }
    return null;
  }
}

/// Last step of the tour: one header, one period row, honest plan cards and a
/// single footer action.
///
/// The page is presentational. The host owns the billing calls so this file
/// stays free of Firebase/plugin imports (and compiles for the web gallery):
///
/// * [onPurchase] receives the exact plan, tier, period and catalogue product
///   id. It must call the real purchase seam for that product.
/// * [onRestorePurchases] must call the real restore and report what happened.
/// * [onManageSubscription] opens the store's subscription controls.
class PaywallPage extends StatefulWidget {
  const PaywallPage({
    super.key,
    this.data = const V2PaywallData(),
    this.onPlanSelected,
    this.onCurrencyChanged,
    this.onPeriodChanged,
    this.onPurchase,
    this.onStartTrial,
    this.onContinueFree,
    this.onRetry,
    this.onRestorePurchases,
    this.onManageSubscription,
    this.onClose,
    this.step = const V2OnboardingStepData(
      step: V2OnboardingTour.plan,
      totalSteps: V2OnboardingTour.totalSteps,
      trailingLabel: '',
    ),
  });

  final V2PaywallData data;
  final ValueChanged<String>? onPlanSelected;
  final ValueChanged<V2Currency>? onCurrencyChanged;
  final ValueChanged<V2PaywallPeriod>? onPeriodChanged;

  /// The period-aware purchase path. Receives a non-null [V2PaywallPurchase]
  /// only when the plan has a price and a catalogue product for the selected
  /// period.
  final Future<void> Function(V2PaywallPurchase purchase)? onPurchase;

  /// Legacy monthly-only callback. It is used only while Monthly is selected;
  /// a yearly selection never falls back to it, because that would buy the
  /// monthly product for a yearly price.
  final ValueChanged<String>? onStartTrial;

  /// Declines the upgrade and enters the app on the Free plan.
  final VoidCallback? onContinueFree;

  final VoidCallback? onRetry;

  /// Real restore entry point. The result is surfaced by the banner.
  final Future<V2PaywallRestoreResult> Function()? onRestorePurchases;

  /// Opens the store's own subscription controls. Required to turn the paid
  /// call to action into Manage.
  final VoidCallback? onManageSubscription;
  final VoidCallback? onClose;

  final V2OnboardingStepData step;

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  late String _selectedPlanId = widget.data.selectedPlanId;
  late V2Currency _currency = widget.data.currency;
  late V2PaywallPeriod _period = widget.data.period;

  bool _purchaseInFlight = false;
  bool _restoring = false;
  String? _pendingPlanId;

  /// The outcome of the last purchase/restore performed on this screen. It
  /// takes precedence over the host's status until the host reports a new one.
  V2PurchaseBannerStatus? _localStatus;
  String? _localDetail;
  VoidCallback? _retryAction;

  bool get _purchaseBusy => widget.data.purchasing || _purchaseInFlight;
  bool get _busy => _purchaseBusy || _restoring;

  @override
  void didUpdateWidget(covariant PaywallPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.selectedPlanId != oldWidget.data.selectedPlanId) {
      _selectedPlanId = widget.data.selectedPlanId;
    }
    if (widget.data.currency != oldWidget.data.currency) {
      _currency = widget.data.currency;
    }
    if (widget.data.period != oldWidget.data.period) {
      _period = widget.data.period;
    }
    if (widget.data.purchaseStatus != oldWidget.data.purchaseStatus ||
        widget.data.error != oldWidget.data.error) {
      _localStatus = null;
      _localDetail = null;
      _retryAction = null;
    }
  }

  void _selectPlan(String id) {
    if (_busy || id == _selectedPlanId) return;
    setState(() => _selectedPlanId = id);
    widget.onPlanSelected?.call(id);
  }

  void _selectCurrency(V2Currency currency) {
    if (_busy || currency == _currency) return;
    setState(() => _currency = currency);
    widget.onCurrencyChanged?.call(currency);
  }

  void _selectPeriod(V2PaywallPeriod period) {
    if (_busy || period == _period) return;
    setState(() {
      _period = period;
      _localDetail = null;
    });
    widget.onPeriodChanged?.call(period);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final hasPlans = !data.loading && data.plans.isNotEmpty;
    final selectedPlan = hasPlans ? _selectedPlan(data) : null;
    final subscribed = data.currentPlanId != null;
    final Widget body;
    if (data.loading) {
      body = const OSkeletonList(rows: 6);
    } else if (data.plans.isEmpty && data.error != null) {
      body = OErrorState(
        title: 'Plans did not load',
        message: data.error!,
        onRetry: widget.onRetry,
      );
    } else if (data.plans.isEmpty) {
      body = OEmptyState(
        icon: Icons.workspace_premium_rounded,
        title: 'No plans right now',
        message: 'Check back in a moment.',
        action: widget.onRetry == null
            ? null
            : OButton(label: 'Try again', onPressed: widget.onRetry),
      );
    } else {
      body = _content(context, data, selectedPlan!);
    }

    final canPrimary =
        selectedPlan != null &&
        !_busy &&
        (subscribed
            ? widget.onManageSubscription != null
            : selectedPlan.isFree
            ? widget.onContinueFree != null
            : _canPurchase(selectedPlan));

    return OnboardingStepScaffold(
      step: widget.step,
      title: 'Upgrade',
      subtitle: 'Choose a plan',
      onClose: _busy ? null : widget.onClose,
      primaryKey: const Key('paywall-trial'),
      primaryLabel: _primaryLabel(selectedPlan, subscribed),
      primaryIcon: subscribed ? Icons.open_in_new_rounded : null,
      primaryLoading: _purchaseBusy,
      primaryVisible: hasPlans,
      loadingLabel: 'Purchasing…',
      footerNote: _footerNote(selectedPlan, subscribed),
      scrollable: !data.loading,
      onPrimary: canPrimary
          ? () => _primaryAction(selectedPlan, subscribed)
          : null,
      secondaryActions: [
        // A visible way out that does not depend on finding the close icon:
        // declining is a real, supported outcome.
        if (!subscribed &&
            selectedPlan != null &&
            !selectedPlan.isFree &&
            widget.onContinueFree != null)
          OTextAction(
            key: const Key('paywall-continue-free'),
            label: 'Continue with Free',
            onPressed: _busy ? null : widget.onContinueFree,
          ),
      ],
      child: body,
    );
  }

  V2PlanOption _selectedPlan(V2PaywallData data) {
    for (final plan in data.plans) {
      if (plan.id == _selectedPlanId) return plan;
    }
    return data.plans.first;
  }

  String _primaryLabel(V2PlanOption? plan, bool subscribed) {
    if (subscribed) return 'Manage';
    if (plan == null) return 'Continue';
    if (plan.isFree) return 'Continue free';
    // Availability wins over the trial promise: a missing product or price
    // must never be presented as a working free trial.
    if (!_canPurchase(plan)) return 'Not available';
    if (widget.data.trialDays > 0) return 'Start free trial';
    return 'Subscribe';
  }

  String? _footerNote(V2PlanOption? plan, bool subscribed) {
    if (plan == null) return null;
    if (subscribed) {
      return widget.onManageSubscription == null
          ? 'Manage subscription is unavailable.'
          : null;
    }
    if (plan.isFree) {
      return widget.onContinueFree == null
          ? 'Free action is unavailable.'
          : null;
    }
    final reason = _disabledReason(plan);
    if (reason != null) return reason;
    if (plan.storeAvailableFor(_period) == null) {
      // The store has not answered for this build. Do not imply the plan is
      // already on sale; checkout is where the SKU is confirmed.
      return 'Play confirms at checkout.';
    }
    if (widget.onPurchase == null && widget.onStartTrial == null) {
      return 'Checkout is not connected.';
    }
    return null;
  }

  Future<void> _primaryAction(V2PlanOption plan, bool subscribed) async {
    if (_busy) return;
    if (subscribed) {
      widget.onManageSubscription?.call();
      return;
    }
    if (plan.isFree) {
      widget.onContinueFree?.call();
      return;
    }
    await _buy(plan);
  }

  Future<void> _onCardAction(V2PlanOption plan) async {
    if (_busy) return;
    if (widget.data.currentPlanId != null) {
      widget.onManageSubscription?.call();
      return;
    }
    _selectPlan(plan.id);
    if (plan.isFree) {
      widget.onContinueFree?.call();
      return;
    }
    if (!_canPurchase(plan)) return;
    await _buy(plan);
  }

  /// True when this plan and period can reach a real purchase call.
  bool _canPurchase(V2PlanOption plan) {
    if (plan.isFree) return widget.onContinueFree != null;
    // A build-level block (e.g. RevenueCat with no server confirmation) makes
    // every paid CTA unavailable, whatever the card's product/price state.
    if (widget.data.checkoutBlockedReason != null) return false;
    if (plan.productIdFor(_period) == null ||
        !plan.hasPrice(_currency, _period)) {
      return false;
    }
    // The store has been queried and does not sell this period: disable rather
    // than attempt a SKU that does not exist.
    if (plan.storeAvailableFor(_period) == false) return false;
    if (widget.onPurchase != null) return true;
    return widget.onStartTrial != null && _period == V2PaywallPeriod.monthly;
  }

  String? _disabledReason(V2PlanOption plan) {
    if (widget.data.currentPlanId != null) {
      return widget.onManageSubscription == null
          ? 'Manage subscription is unavailable.'
          : null;
    }
    if (plan.isFree) {
      return widget.onContinueFree == null
          ? 'Free action is unavailable.'
          : null;
    }
    final blocked = widget.data.checkoutBlockedReason;
    if (blocked != null) return blocked;
    if (plan.productIdFor(_period) == null) {
      return _period == V2PaywallPeriod.yearly
          ? 'Yearly is not sold for this plan.'
          : 'Monthly is not sold for this plan.';
    }
    if (!plan.hasPrice(_currency, _period)) {
      return _period == V2PaywallPeriod.yearly
          ? 'No yearly price for this plan.'
          : 'No monthly price for this plan.';
    }
    if (plan.storeAvailableFor(_period) == false) {
      return _period == V2PaywallPeriod.yearly
          ? 'Yearly billing is not available in Google Play yet.'
          : 'Monthly billing is not available in Google Play right now.';
    }
    if (widget.onPurchase != null) return null;
    if (widget.onStartTrial == null) return 'Checkout is not connected.';
    if (_period == V2PaywallPeriod.yearly) {
      return 'Yearly checkout is not connected.';
    }
    return null;
  }

  Future<void> _buy(V2PlanOption plan) async {
    if (_busy) return;
    final productId = plan.productIdFor(_period);
    if (productId == null) return;
    final purchase = V2PaywallPurchase(
      planId: plan.id,
      tier: plan.tier,
      period: _period,
      productId: productId,
    );
    setState(() {
      _purchaseInFlight = true;
      _pendingPlanId = plan.id;
      _localStatus = null;
      _localDetail = null;
      _retryAction = null;
    });
    try {
      if (widget.onPurchase != null) {
        await widget.onPurchase!(purchase);
      } else if (widget.onStartTrial != null &&
          _period == V2PaywallPeriod.monthly) {
        // Legacy host. The host owns the in-flight flag for this path.
        widget.onStartTrial!(plan.id);
      } else {
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _purchaseInFlight = false;
        _pendingPlanId = null;
        _localStatus = V2PurchaseBannerStatus.failed;
        _localDetail = 'The purchase did not finish.';
        _retryAction = () => _buy(plan);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _purchaseInFlight = false;
      _pendingPlanId = null;
    });
  }

  Future<void> _restore() async {
    final restore = widget.onRestorePurchases;
    if (restore == null || _busy) return;
    setState(() {
      _restoring = true;
      _localStatus = null;
      _localDetail = null;
      _retryAction = null;
    });
    try {
      final result = await restore();
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _localStatus = switch (result) {
          V2PaywallRestoreResult.restored => V2PurchaseBannerStatus.restored,
          V2PaywallRestoreResult.nothingToRestore =>
            V2PurchaseBannerStatus.nothingToRestore,
          V2PaywallRestoreResult.failed => V2PurchaseBannerStatus.failed,
        };
        _localDetail = result == V2PaywallRestoreResult.failed
            ? 'The restore did not finish.'
            : null;
        _retryAction = result == V2PaywallRestoreResult.failed
            ? _restore
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _localStatus = V2PurchaseBannerStatus.failed;
        _localDetail = 'The restore did not finish.';
        _retryAction = _restore;
      });
    }
  }

  /// One banner for every billing notice on the paywall.
  ///
  /// A local purchase/restore result wins. Otherwise the host's explicit
  /// [V2PaywallData.purchaseStatus] is used, then the legacy [error] and
  /// [testModeNote] fields, so older hosts do not lose their notice.
  V2PurchaseBannerData _bannerData(
    V2PaywallData data,
    V2PlanOption selectedPlan,
  ) {
    final status =
        _localStatus ??
        data.purchaseStatus ??
        (data.error != null
            ? V2PurchaseBannerStatus.failed
            : data.testModeNote != null
            ? V2PurchaseBannerStatus.testStore
            : V2PurchaseBannerStatus.hidden);
    final detail =
        _localDetail ??
        data.purchaseDetail ??
        switch (status) {
          V2PurchaseBannerStatus.failed => data.error,
          V2PurchaseBannerStatus.testStore => data.testModeNote,
          _ => null,
        };
    return V2PurchaseBannerData(
      status: status,
      // A local restore only knows that a purchase was found, not which plan;
      // naming the selected card would guess.
      planName: _localStatus != null ? null : selectedPlan.name,
      detail: detail,
    );
  }

  Widget _content(
    BuildContext context,
    V2PaywallData data,
    V2PlanOption selectedPlan,
  ) {
    final c = OColors.of(context);
    final banner = _bannerData(data, selectedPlan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _PeriodToggle(
              period: _period,
              onChanged: _busy ? null : _selectPeriod,
            ),
            _CurrencyToggle(
              currency: _currency,
              onChanged: _busy ? null : _selectCurrency,
            ),
          ],
        ),
        const SizedBox(height: OSpace.l),
        _PlanGrid(
          cards: [for (final plan in data.plans) _card(context, data, plan)],
        ),
        const SizedBox(height: OSpace.l),
        OButton(
          key: const Key('paywall-restore'),
          label: 'Restore purchases',
          icon: Icons.restore_rounded,
          variant: OButtonVariant.secondary,
          expand: true,
          loading: _restoring,
          semanticLabel: _restoring
              ? 'Restore purchases, loading'
              : widget.onRestorePurchases == null
              ? 'Restore purchases, not connected'
              : 'Restore purchases',
          onPressed: widget.onRestorePurchases == null || _busy
              ? null
              : _restore,
        ),
        // The billing promise only appears when a paid plan can actually reach
        // the store. With no product in Play (or a blocked checkout) the cards
        // say why, and this line would claim a purchase that cannot happen.
        if (!selectedPlan.isFree && _canPurchase(selectedPlan)) ...[
          const SizedBox(height: OSpace.l),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.verified_user_rounded, size: 16, color: c.success),
              const SizedBox(width: OSpace.iconGap),
              Flexible(
                child: Text(
                  'Cancel anytime. Billed by Google Play.',
                  textAlign: TextAlign.center,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
        if (banner.status != V2PurchaseBannerStatus.hidden) ...[
          const SizedBox(height: OSpace.l),
          V2PurchaseBanner(
            data: banner,
            onRetry: _retryAction ?? widget.onRetry,
            onManageSubscription: widget.onManageSubscription,
          ),
        ],
      ],
    );
  }

  Widget _card(BuildContext context, V2PaywallData data, V2PlanOption plan) {
    final c = OColors.of(context);
    final current =
        data.currentPlanId != null &&
        plan.canonicalId == V2PlanOption.canonicalIdFor(data.currentPlanId!);
    final selected = plan.id == _selectedPlanId;
    final disabledReason = _disabledReason(plan);
    // The owned plan is a status, not another purchase: keep it visibly
    // disabled even when management is available.
    final enabled = !_busy && !current && disabledReason == null;
    final inFlight =
        (_purchaseInFlight && _pendingPlanId == plan.id) ||
        (data.purchasing && (selected || current));
    final label = _cardLabel(plan, current);
    final price = plan.priceFor(_currency, _period);
    final priceKnown = plan.hasPrice(_currency, _period);
    final groupLabel = [
      plan.name,
      priceKnown ? '$price ${plan.periodPhrase(_period)}' : 'price unavailable',
      plan.modelAccessLabel,
      if (current) 'current plan',
    ].join(', ');
    String? reason;
    if (current) {
      reason = 'already subscribed';
    } else if (disabledReason != null) {
      reason = disabledReason;
    } else if (_busy) {
      reason = _restoring ? 'restore in progress' : 'purchase in progress';
    }
    final ctaSemantic = reason == null
        ? '$label, ${plan.name}, $price ${plan.periodPhrase(_period)}'
        : '$label, ${plan.name}, $reason';

    return Semantics(
      key: Key('paywall-plan-${plan.id}'),
      container: true,
      explicitChildNodes: true,
      label: groupLabel,
      selected: selected || current,
      inMutuallyExclusiveGroup: true,
      onTap: _busy ? null : () => _selectPlan(plan.id),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : () => _selectPlan(plan.id),
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          padding: const EdgeInsets.all(OSpace.l),
          decoration: BoxDecoration(
            color: selected || current ? c.accentSoft : c.surface,
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(
              color: selected || current
                  ? c.accentFill.withValues(alpha: 0.50)
                  : c.hairline,
              width: selected || current ? 1.5 : 1,
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
              final stacked = constraints.maxWidth < 210 || scale > 1.3;
              final name = ExcludeSemantics(
                child: Text(plan.name, style: OType.h3.copyWith(color: c.text)),
              );
              final priceBlock = ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: stacked
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      price,
                      style: OType.h3.copyWith(
                        color: selected || current ? c.accent : c.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      plan.periodSuffix(_period),
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (stacked) ...[
                    name,
                    const SizedBox(height: OSpace.xs),
                    priceBlock,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: name),
                        const SizedBox(width: OSpace.s),
                        priceBlock,
                      ],
                    ),
                  const SizedBox(height: OSpace.s),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ExcludeSemantics(
                      child: OPill(
                        key: Key('plan-access-${plan.id}'),
                        label: plan.modelAccessLabel,
                        tone: plan.autoOnly
                            ? OPillTone.neutral
                            : OPillTone.success,
                        icon: plan.autoOnly
                            ? Icons.lock_outline_rounded
                            : Icons.tune_rounded,
                      ),
                    ),
                  ),
                  if (plan.features.isNotEmpty) ...[
                    const SizedBox(height: OSpace.m),
                    for (final feature in plan.features.take(3))
                      Padding(
                        padding: const EdgeInsets.only(top: OSpace.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: OSpace.xxs),
                              child: Icon(
                                Icons.check_rounded,
                                size: 14,
                                color: c.textMuted,
                              ),
                            ),
                            const SizedBox(width: OSpace.s),
                            Expanded(
                              child: Text(
                                feature,
                                style: OType.bodySm.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: OSpace.l),
                  OButton(
                    key: Key('paywall-cta-${plan.id}'),
                    label: label,
                    variant: selected
                        ? OButtonVariant.primary
                        : OButtonVariant.secondary,
                    expand: true,
                    loading: inFlight,
                    semanticLabel: ctaSemantic,
                    onPressed: enabled ? () => _onCardAction(plan) : null,
                  ),
                  if (disabledReason != null && !current) ...[
                    const SizedBox(height: OSpace.xs),
                    Text(
                      disabledReason,
                      key: Key('paywall-unavailable-${plan.id}'),
                      textAlign: TextAlign.center,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  String _cardLabel(V2PlanOption plan, bool current) {
    if (widget.data.currentPlanId != null) {
      return current ? 'Current plan' : 'Manage';
    }
    if (plan.isFree) return 'Continue free';
    if (_disabledReason(plan) != null) return 'Not available';
    if (widget.data.trialDays > 0) return 'Start trial';
    return 'Choose ${plan.shortName}';
  }
}

/// One column on a phone, two columns of cards from 600 dp. A card may become
/// a grid cell; a row never becomes a column.
class _PlanGrid extends StatelessWidget {
  const _PlanGrid({required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    // The band comes from the window, not from the (already capped) content
    // width: at exactly 600 dp the page is a tablet even though its content
    // column is only 552 dp wide.
    final columns = OResponsive.of(context).isTablet ? 2 : 1;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(height: OSpace.m),
                cards[i],
              ],
            ],
          );
        }
        final itemWidth = (constraints.maxWidth - OSpace.m) / 2;
        return Wrap(
          spacing: OSpace.m,
          runSpacing: OSpace.m,
          children: [
            for (final card in cards) SizedBox(width: itemWidth, child: card),
          ],
        );
      },
    );
  }
}

class _PeriodToggle extends StatelessWidget {
  const _PeriodToggle({required this.period, required this.onChanged});

  final V2PaywallPeriod period;
  final ValueChanged<V2PaywallPeriod>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _SegmentedToggle(
      children: [
        _ToggleOption(
          key: const Key('paywall-period-monthly'),
          label: 'Monthly',
          selected: period == V2PaywallPeriod.monthly,
          onTap: onChanged == null
              ? null
              : () => onChanged!(V2PaywallPeriod.monthly),
        ),
        _ToggleOption(
          key: const Key('paywall-period-yearly'),
          label: 'Yearly',
          selected: period == V2PaywallPeriod.yearly,
          onTap: onChanged == null
              ? null
              : () => onChanged!(V2PaywallPeriod.yearly),
        ),
      ],
    );
  }
}

/// States the model access a tier actually has. Free and Go are Auto-only;
/// saying so on the card is part of the product, not decoration.
class _CurrencyToggle extends StatelessWidget {
  const _CurrencyToggle({required this.currency, required this.onChanged});

  final V2Currency currency;
  final ValueChanged<V2Currency>? onChanged;

  @override
  Widget build(BuildContext context) {
    return _SegmentedToggle(
      children: [
        _ToggleOption(
          key: const Key('paywall-currency-usd'),
          label: 'USD (\$)',
          semanticLabel: 'US dollars',
          selected: currency == V2Currency.usd,
          onTap: onChanged == null ? null : () => onChanged!(V2Currency.usd),
        ),
        _ToggleOption(
          key: const Key('paywall-currency-inr'),
          label: 'INR (₹)',
          semanticLabel: 'Indian rupees',
          selected: currency == V2Currency.inr,
          onTap: onChanged == null ? null : () => onChanged!(V2Currency.inr),
        ),
      ],
    );
  }
}

class _SegmentedToggle extends StatelessWidget {
  const _SegmentedToggle({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: OSpace.xxs),
            Flexible(child: children[i]),
          ],
        ],
      ),
    );
  }
}

class _ToggleOption extends StatelessWidget {
  const _ToggleOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.semanticLabel,
  });

  final String label;
  final String? semanticLabel;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: semanticLabel ?? label,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      enabled: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: OSpace.xs,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.accentFill : Colors.transparent,
            borderRadius: BorderRadius.circular(ORadius.pill),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(
              color: selected ? c.onAccent : c.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

String _groupDigits(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(',');
    buffer.write(digits[index]);
  }
  return buffer.toString();
}

String _groupInr(int value) {
  final digits = value.toString();
  if (digits.length <= 3) return digits;
  final lastThree = digits.substring(digits.length - 3);
  var rest = digits.substring(0, digits.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '${groups.join(',')},$lastThree';
}
