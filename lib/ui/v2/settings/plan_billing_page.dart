// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../../core/billing_products.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'plan_compare_table.dart';
import 'settings_rows.dart';

enum V2PlanBillingStatus { loading, ready, empty, error }

enum V2Currency { usd, inr }

enum V2BillingPeriod { monthly, yearly }

/// The authoritative plan table. Every limit is per user: storage, project
/// size, model access and the custom-connector slots.
///
/// The token ceilings are Free-only: 50M / 24 h and 1.5B / 30 d, enforced by
/// `server/mint/ovid_plans.py`. Paid plans are never token-capped (their
/// allowance is the Free USD allowance × the server's plan multiplier), so
/// their caps are 0 here and the UI states "No token cap".
@immutable
class V2PlanLimits {
  const V2PlanLimits({
    required this.id,
    required this.name,
    required this.storageGb,
    required this.filesPerWindow,
    required this.fileWindowLabel,
    required this.filesPerProject,
    required this.manualModels,
    required this.autoMultiplier,
    required this.customConnectors,
    required this.dailyTokenCap,
    required this.monthlyTokenCap,
  });

  /// Canonical id (`free`, `go`, `plus`, `pro`).
  final String id;
  final String name;
  final int storageGb;
  final int filesPerWindow;

  /// `day` for Free, `3 h` for the paid plans.
  final String fileWindowLabel;
  final int filesPerProject;
  final bool manualModels;
  final num autoMultiplier;
  final int customConnectors;
  final int dailyTokenCap;
  final int monthlyTokenCap;

  static const free = V2PlanLimits(
    id: 'free',
    name: 'Free',
    storageGb: 3,
    filesPerWindow: 50,
    fileWindowLabel: 'day',
    filesPerProject: 80,
    manualModels: false,
    autoMultiplier: 1,
    customConnectors: 0,
    dailyTokenCap: 50000000,
    monthlyTokenCap: 1500000000,
  );

  static const go = V2PlanLimits(
    id: 'go',
    name: 'Ovid Go',
    storageGb: 5,
    filesPerWindow: 80,
    fileWindowLabel: '3 h',
    filesPerProject: 100,
    manualModels: false,
    autoMultiplier: 3,
    customConnectors: 5,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  static const plus = V2PlanLimits(
    id: 'plus',
    name: 'Ovid Plus',
    storageGb: 15,
    filesPerWindow: 80,
    fileWindowLabel: '3 h',
    filesPerProject: 150,
    manualModels: true,
    autoMultiplier: 23,
    customConnectors: 20,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  static const pro = V2PlanLimits(
    id: 'pro',
    name: 'Ovid Pro',
    storageGb: 75,
    filesPerWindow: 80,
    fileWindowLabel: '3 h',
    filesPerProject: 250,
    manualModels: true,
    autoMultiplier: 43,
    customConnectors: 20,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  /// Table order: Free, Go, Plus, Pro.
  static const plans = <V2PlanLimits>[free, go, plus, pro];

  /// Resolves server tier ids (`3x`, `7x`, `15x`), plan ids (`go`, `plus`,
  /// `pro`) and the display names to the canonical table.
  static V2PlanLimits? forId(String id) {
    final key = id.trim().toLowerCase().replaceAll(RegExp(r'[_\-]+'), ' ');
    return switch (key) {
      'free' || 'free plan' => free,
      'go' || 'ovid go' || '3x' || 'starter' => go,
      'plus' || 'ovid plus' || '7x' => plus,
      'pro' || 'ovid pro' || '15x' || 'max' => pro,
      _ => null,
    };
  }

  static V2PlanLimits forIdOrFree(String? id) =>
      (id == null ? null : forId(id)) ?? free;

  /// Resolves a plan from its storage allowance (`3 GB`, `5 GB`, …). Used
  /// only when the caller has not supplied a plan id.
  static V2PlanLimits? forStorageGb(int? gb) {
    if (gb == null) return null;
    for (final plan in plans) {
      if (plan.storageGb == gb) return plan;
    }
    return null;
  }

  V2PlanLimits withStorage(int gb) => V2PlanLimits(
    id: id,
    name: name,
    storageGb: gb,
    filesPerWindow: filesPerWindow,
    fileWindowLabel: fileWindowLabel,
    filesPerProject: filesPerProject,
    manualModels: manualModels,
    autoMultiplier: autoMultiplier,
    customConnectors: customConnectors,
    dailyTokenCap: dailyTokenCap,
    monthlyTokenCap: monthlyTokenCap,
  );

  String get storageLabel => '$storageGb GB';

  /// `50 files / day` or `80 files / 3 h`.
  String get filesLabel => '$filesPerWindow files / $fileWindowLabel';

  String get filesPerProjectLabel => '$filesPerProject files max / project';

  String get modelAccessLabel =>
      manualModels ? 'Auto + manual models' : 'Auto only';

  String get autoMultiplierLabel => '${formatMultiplier(autoMultiplier)}×';

  String get autoAllowanceLabel =>
      '${formatMultiplier(autoMultiplier)}× Free allowance';

  String get customConnectorsLabel => customConnectors == 0
      ? 'No custom connectors'
      : '$customConnectors custom connectors';

  String get dailyCapLabel =>
      dailyTokenCap <= 0 ? 'No token cap' : _groupDigits(dailyTokenCap);

  String get monthlyCapLabel =>
      monthlyTokenCap <= 0 ? 'No token cap' : _groupDigits(monthlyTokenCap);

  String get dailyCapDescription =>
      dailyTokenCap <= 0 ? 'No token cap' : '$dailyCapLabel tokens / 24 h';

  String get monthlyCapDescription => monthlyTokenCap <= 0
      ? 'No token cap'
      : '$monthlyCapLabel tokens / 30 days';
}

/// `1` → `1`, `1.5` → `1.5`, `20` → `20`.
String formatMultiplier(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

/// The authoritative prices from the product spec (§11): Go $5 / ₹499,
/// Plus $18 / ₹1,799, Pro $99 / ₹9,999, Free $0.
///
/// Yearly is ten monthly payments (two months free), the same rule
/// `V2SettingsRoutes` applies when it builds the live plan list. This table is
/// the fallback for a caller that omits a price; it is never used to override
/// a price the caller (or the store) supplies. A period without a known price
/// resolves to null and the card disables its CTA instead of inventing
/// `monthly × 12`, which is a number the store would never charge.
@immutable
class V2PlanPrices {
  const V2PlanPrices({
    required this.monthlyUsd,
    required this.monthlyInr,
    required this.yearlyUsd,
    required this.yearlyInr,
  });

  final int monthlyUsd;
  final int monthlyInr;
  final int yearlyUsd;
  final int yearlyInr;

  int monthly(V2Currency currency) =>
      currency == V2Currency.inr ? monthlyInr : monthlyUsd;

  int yearly(V2Currency currency) =>
      currency == V2Currency.inr ? yearlyInr : yearlyUsd;

  static const free = V2PlanPrices(
    monthlyUsd: 0,
    monthlyInr: 0,
    yearlyUsd: 0,
    yearlyInr: 0,
  );

  static const go = V2PlanPrices(
    monthlyUsd: 5,
    monthlyInr: 499,
    yearlyUsd: 50,
    yearlyInr: 4990,
  );

  static const plus = V2PlanPrices(
    monthlyUsd: 18,
    monthlyInr: 1799,
    yearlyUsd: 180,
    yearlyInr: 17990,
  );

  static const pro = V2PlanPrices(
    monthlyUsd: 99,
    monthlyInr: 9999,
    yearlyUsd: 990,
    yearlyInr: 99990,
  );

  static const plans = <V2PlanPrices>[free, go, plus, pro];

  /// Resolves a plan id (`go`, `3x`) or a display name (`Ovid Plus`) to the
  /// canonical price row.
  static V2PlanPrices? forPlan(String id, [String? name]) {
    final canonical =
        V2PlanLimits.forId(id) ??
        (name == null ? null : V2PlanLimits.forId(name));
    return switch (canonical?.id) {
      'free' => free,
      'go' => go,
      'plus' => plus,
      'pro' => pro,
      _ => null,
    };
  }
}

@immutable
class V2Plan {
  const V2Plan({
    required this.id,
    required this.name,
    required this.tagline,
    required this.priceUsd,
    required this.priceInr,
    this.priceUsdYearly = 0,
    this.priceInrYearly = 0,
    this.storageGb = 0,
    this.autoOnly = false,
    this.limits,
    this.features = const [],
    this.popular = false,
    this.ctaLabel,
    this.storePriceMonthly,
    this.storePriceYearly,
    this.storeCurrency,
    this.storeMonthlyAvailable,
    this.storeYearlyAvailable,
  });

  final String id;
  final String name;
  final String tagline;
  final int priceUsd;
  final int priceInr;
  final int priceUsdYearly;
  final int priceInrYearly;
  final int storageGb;
  final bool autoOnly;

  /// Optional explicit limits. When null the canonical [V2PlanLimits] for
  /// [id] (or the plan name) is used, so server-built plans still show the
  /// exact product-spec numbers.
  final V2PlanLimits? limits;
  final List<String> features;
  final bool popular;
  final String? ctaLabel;

  /// The store's own localised price for each period, when the store was
  /// queried and sells it. This is what the card shows when available: the
  /// canonical table is only a fallback, never an override.
  final String? storePriceMonthly;
  final String? storePriceYearly;

  /// ISO currency of the store prices (`USD`, `INR`). The price string already
  /// carries its symbol; this records which currency the store quoted.
  final String? storeCurrency;

  /// Whether the store sells the period. Null = not queried yet; false
  /// disables the CTA with a reason instead of attempting a missing SKU.
  final bool? storeMonthlyAvailable;
  final bool? storeYearlyAvailable;

  /// Canonical plan id (`free`, `go`, `plus`, `pro`) for this plan.
  ///
  /// Server tiers use `3x`/`7x`/`15x`; the store sells them as Go/Plus/Pro.
  /// Resolving through [planLimits] means a card, its comparison column and
  /// the purchase request always name the same plan.
  String get canonicalId => planLimits.id;

  /// The Google Play / RevenueCat product for [period], or null for Free.
  String? productIdFor(V2BillingPeriod period) =>
      V2PlanProducts.forPlan(canonicalId, period);

  /// The limits to render for this plan. Explicit [limits] win; otherwise the
  /// canonical table fills in everything the server does not send.
  V2PlanLimits get planLimits {
    final canonical = V2PlanLimits.forId(id) ?? V2PlanLimits.forId(name);
    final base = limits ?? canonical;
    if (base == null) {
      return V2PlanLimits(
        id: id,
        name: name,
        storageGb: storageGb,
        filesPerWindow: 0,
        fileWindowLabel: 'day',
        filesPerProject: 0,
        manualModels: !autoOnly,
        autoMultiplier: 1,
        customConnectors: 0,
        dailyTokenCap: 0,
        monthlyTokenCap: 0,
      );
    }
    if (storageGb > 0 && storageGb != base.storageGb) {
      return base.withStorage(storageGb);
    }
    return base;
  }

  /// The product-spec prices for this plan, when it is one of the four plans
  /// the spec prices. Custom/server plans have no canonical row.
  V2PlanPrices? get canonicalPrices => V2PlanPrices.forPlan(id, name);

  /// The price for [period], or null when neither the caller nor the product
  /// spec knows one. Free is always 0, never null.
  ///
  /// A yearly request never borrows the monthly price (and never multiplies
  /// it): a plan with no yearly price is not sold yearly.
  int? amount(V2Currency currency, V2BillingPeriod period) {
    if (canonicalId == 'free') return 0;
    final canonical = canonicalPrices;
    if (period == V2BillingPeriod.monthly) {
      final monthly = currency == V2Currency.inr ? priceInr : priceUsd;
      if (monthly > 0) return monthly;
      final fallback = canonical?.monthly(currency) ?? 0;
      return fallback > 0 ? fallback : null;
    }
    final yearly = currency == V2Currency.inr ? priceInrYearly : priceUsdYearly;
    if (yearly > 0) return yearly;
    final fallback = canonical?.yearly(currency) ?? 0;
    return fallback > 0 ? fallback : null;
  }

  bool hasPrice(V2Currency currency, V2BillingPeriod period) =>
      amount(currency, period) != null;

  /// The store's price for [period], or null when the store was not queried
  /// or does not sell it.
  ///
  /// The store string already carries its own currency (Play localises it), so
  /// it wins over the currency toggle: the card must show the amount Google
  /// Play will actually charge.
  String? storePriceFor(V2Currency currency, V2BillingPeriod period) {
    final price = period == V2BillingPeriod.yearly
        ? storePriceYearly
        : storePriceMonthly;
    if (price == null || price.trim().isEmpty) return null;
    return price;
  }

  /// null = the store has not been queried; false = it does not sell [period].
  bool? storeAvailableFor(V2BillingPeriod period) =>
      period == V2BillingPeriod.yearly
      ? storeYearlyAvailable
      : storeMonthlyAvailable;

  /// `$18`, `₹1,799`, the store's localised price, or `—` when this period has
  /// no price at all.
  String priceLabel(
    V2Currency currency, {
    V2BillingPeriod period = V2BillingPeriod.monthly,
  }) {
    final store = storePriceFor(currency, period);
    if (store != null) return store;
    final amount = this.amount(currency, period);
    if (amount == null) return '—';
    final symbol = currency == V2Currency.inr ? '₹' : r'$';
    return '$symbol${_groupDigits(amount)}';
  }

  String periodSuffix(V2BillingPeriod period) =>
      period == V2BillingPeriod.monthly ? '/ month' : '/ year';

  /// `per month` / `per year`, for a spoken price.
  String periodPhrase(V2BillingPeriod period) =>
      period == V2BillingPeriod.monthly ? 'per month' : 'per year';

  /// The CTA names the plan, never the direction. "Upgrade to Plus" is wrong
  /// on a Pro account; the card's own name already says which plan is bought.
  String get actionLabel =>
      ctaLabel ??
      (canonicalId == 'free'
          // A paid account downgrades/cancels in Play, it never "selects Free".
          ? 'Manage in Play'
          : 'Select $name');
}

/// The store products each plan is sold as, per billing period.
///
/// Both maps are derived from the billing layer's [kOvidPlayProductIds], so a
/// period that has no product configured (a missing Play base plan or a plan
/// the store does not sell) resolves to null and the card disables its CTA
/// instead of buying a different SKU.
abstract final class V2PlanProducts {
  static final Map<String, String> monthly = _productsFor(
    OvidBillingPeriod.monthly,
  );

  static final Map<String, String> yearly = _productsFor(
    OvidBillingPeriod.yearly,
  );

  /// Canonical plan id → server/RevenueCat tier id.
  static const tiers = <String, String>{
    'free': 'free',
    'go': '3x',
    'plus': '7x',
    'pro': '15x',
  };

  static Map<String, String> _productsFor(OvidBillingPeriod period) {
    final out = <String, String>{};
    for (final entry in tiers.entries) {
      final productId = ovidPlayProductId(entry.value, period);
      if (productId != null) out[entry.key] = productId;
    }
    return out;
  }

  static String? forPlan(String planId, V2BillingPeriod period) =>
      (period == V2BillingPeriod.yearly ? yearly : monthly)[planId];

  static String tierForPlan(String planId) => tiers[planId] ?? planId;
}

/// Maps the screen's period onto the billing layer's period.
OvidBillingPeriod ovidPeriodFor(V2BillingPeriod period) =>
    period == V2BillingPeriod.yearly
    ? OvidBillingPeriod.yearly
    : OvidBillingPeriod.monthly;

/// One purchase request from a plan card: which plan, which product and which
/// billing period. The page never picks a tier on the user's behalf.
@immutable
class V2PlanPurchase {
  const V2PlanPurchase({required this.plan, required this.period});

  final V2Plan plan;
  final V2BillingPeriod period;

  /// Canonical plan id (`free`, `go`, `plus`, `pro`).
  String get planId => plan.canonicalId;

  /// Server/RevenueCat tier id (`free`, `3x`, `7x`, `15x`).
  String get tier => V2PlanProducts.tierForPlan(planId);

  /// The store product for this plan and period; null for Free.
  String? get productId => plan.productIdFor(period);
}

@immutable
class V2BillingHistoryEntry {
  const V2BillingHistoryEntry({
    required this.id,
    required this.title,
    required this.dateLabel,
    required this.amountLabel,
    this.statusLabel = 'Paid',
  });

  final String id;
  final String title;
  final String dateLabel;
  final String amountLabel;
  final String statusLabel;
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

@immutable
class V2PlanBillingData {
  const V2PlanBillingData({
    this.status = V2PlanBillingStatus.ready,
    this.currency = V2Currency.usd,
    this.period = V2BillingPeriod.monthly,
    this.currentPlanId = 'free',
    this.plans = const [],
    this.history = const [],
    this.onCurrencyChanged,
    this.onPeriodChanged,
    this.onPurchase,
    this.onRestorePurchases,
    this.onHistoryTap,
    this.onRetry,
    this.checkoutBlockedReason,
    this.errorMessage =
        'We could not load plans. Check your connection and try again.',
  });

  final V2PlanBillingStatus status;
  final V2Currency currency;
  final V2BillingPeriod period;
  final String currentPlanId;
  final List<V2Plan> plans;

  /// Receipts to show. Empty hides the section: this screen has no receipts
  /// source, so an empty list means "unknown", not "this account never paid".
  final List<V2BillingHistoryEntry> history;
  final ValueChanged<V2Currency>? onCurrencyChanged;
  final ValueChanged<V2BillingPeriod>? onPeriodChanged;

  /// The real purchase entry point. It receives the plan the user tapped and
  /// the period currently selected on screen, so the caller never has to guess
  /// a tier (the old screen hard-coded Plus here).
  final ValueChanged<V2PlanPurchase>? onPurchase;

  /// Re-reads owned subscriptions from the store. The owner reports the real
  /// outcome (restored, found but unconfirmed, or the store's error) because
  /// only it can see the result; this page only supplies the entry point.
  final VoidCallback? onRestorePurchases;
  final ValueChanged<V2BillingHistoryEntry>? onHistoryTap;
  final VoidCallback? onRetry;

  /// A build-level reason every paid plan cannot be bought right now, even
  /// when the card has a product and a price (a RevenueCat build with no
  /// server confirmation route). Null means checkout is not globally blocked.
  final String? checkoutBlockedReason;

  final String errorMessage;
}

class PlanBillingPage extends StatelessWidget {
  const PlanBillingPage({super.key, required this.data});

  final V2PlanBillingData data;

  /// The current plan in canonical form (`3x` → `go`), so the badge, the
  /// comparison column and the plan card all agree.
  String get _currentCanonicalId =>
      V2PlanLimits.forId(data.currentPlanId)?.id ?? data.currentPlanId;

  bool _isCurrent(V2Plan plan) =>
      plan.canonicalId == _currentCanonicalId || plan.id == data.currentPlanId;

  /// The page's plans and the selected currency/period are mapped onto the
  /// shared comparison contract, so the table always matches the plan cards.
  V2PlanCompareData _compareData() {
    return V2PlanCompareData(
      plans: [for (final plan in data.plans) _comparePlan(plan)],
      currentPlanId: _currentCanonicalId,
      onRetry: data.onRetry,
    );
  }

  V2PlanComparePlan _comparePlan(V2Plan plan) {
    final limits = plan.planLimits;
    return V2PlanComparePlan(
      id: plan.canonicalId,
      name: plan.name,
      priceLabel: plan.priceLabel(data.currency, period: data.period),
      pricePeriodLabel: plan.periodSuffix(data.period),
      priceAvailable: plan.hasPrice(data.currency, data.period),
      storageGb: limits.storageGb,
      filesPerWindow: limits.filesPerWindow,
      fileWindowHours: _fileWindowHours(limits.fileWindowLabel),
      filesPerProject: limits.filesPerProject,
      manualModels: limits.manualModels,
      autoMultiplier: limits.autoMultiplier,
      customConnectors: limits.customConnectors,
      dailyTokenCap: limits.dailyTokenCap,
      monthlyTokenCap: limits.monthlyTokenCap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2PlanBillingStatus.loading:
        body = const OSkeletonList(rows: 5);
      case V2PlanBillingStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2PlanBillingStatus.empty:
        body = _emptyState();
      case V2PlanBillingStatus.ready:
        body = data.plans.isEmpty ? _emptyState() : _content(context);
    }

    return OScreen(
      title: 'Plan & billing',
      actions: [
        if (data.onRestorePurchases != null)
          OIconButton(
            key: const ValueKey<String>('restore-purchases'),
            icon: Icons.restore_rounded,
            semanticLabel: 'Restore purchases',
            tooltip: 'Restore purchases',
            onPressed: data.onRestorePurchases,
          ),
      ],
      child: body,
    );
  }

  Widget _emptyState() {
    return OEmptyState(
      icon: Icons.sell_outlined,
      title: 'No plans to show',
      message: 'No plans are on sale right now.',
      action: data.onRetry == null
          ? null
          : OButton(
              label: 'Check plans again',
              icon: Icons.refresh_rounded,
              onPressed: data.onRetry,
            ),
    );
  }

  Widget _content(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: OSpace.m,
            runSpacing: OSpace.s,
            children: [
              _BillingPeriodToggle(
                value: data.period,
                onChanged: data.onPeriodChanged,
              ),
              _CurrencyToggle(
                value: data.currency,
                onChanged: data.onCurrencyChanged,
              ),
            ],
          ),
          const SizedBox(height: OSpace.l),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoUp = OResponsive.of(context).isTablet;
              final gap = OSpace.m;
              final cardWidth = twoUp
                  ? (constraints.maxWidth - gap) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final plan in data.plans)
                    SizedBox(
                      width: cardWidth,
                      child: _PlanCard(
                        plan: plan,
                        currency: data.currency,
                        period: data.period,
                        current: _isCurrent(plan),
                        onPurchase: data.onPurchase,
                        checkoutBlockedReason: data.checkoutBlockedReason,
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: OSpace.l),
          OSectionHeader(label: 'Plan limits', padding: EdgeInsets.zero),
          const SizedBox(height: OSpace.s),
          PlanCompareTable(data: _compareData()),
          // Receipts have no source on this screen yet. An always-empty
          // "Payment history" block claimed "No payments yet" even for a paid
          // account, so it is shown only when the caller has real entries.
          if (data.history.isNotEmpty) ...[
            const SizedBox(height: OSpace.l),
            OSectionHeader(label: 'Payment history', padding: EdgeInsets.zero),
            V2SettingsRowList(
              rows: [
                for (final entry in data.history)
                  _HistoryRow(entry: entry, onTap: data.onHistoryTap),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CurrencyToggle extends StatelessWidget {
  const _CurrencyToggle({required this.value, required this.onChanged});

  final V2Currency value;
  final ValueChanged<V2Currency>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _ToggleOption(
              label: 'USD (\$)',
              selected: value == V2Currency.usd,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2Currency.usd),
            ),
          ),
          Flexible(
            child: _ToggleOption(
              label: 'INR (₹)',
              selected: value == V2Currency.inr,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2Currency.inr),
            ),
          ),
        ],
      ),
    );
  }
}

class _BillingPeriodToggle extends StatelessWidget {
  const _BillingPeriodToggle({required this.value, required this.onChanged});

  final V2BillingPeriod value;
  final ValueChanged<V2BillingPeriod>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _ToggleOption(
              label: 'Monthly',
              selected: value == V2BillingPeriod.monthly,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2BillingPeriod.monthly),
            ),
          ),
          Flexible(
            child: _ToggleOption(
              label: 'Yearly',
              selected: value == V2BillingPeriod.yearly,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2BillingPeriod.yearly),
            ),
          ),
        ],
      ),
    );
  }
}

/// One option of a two-state toggle. Both toggles on this page are radio
/// groups, so the option announces its selection and that it is one of a set.
class _ToggleOption extends StatelessWidget {
  const _ToggleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      child: Semantics(
        label: label,
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        enabled: onTap != null,
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: OSpace.xs,
          ),
          decoration: BoxDecoration(
            color: selected ? c.accentFill : c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.pill),
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: OType.label.copyWith(
                color: selected ? c.onAccent : c.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One plan: name, price, a single line, one CTA. Every limit lives in the
/// comparison table below, so the card never repeats it.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.currency,
    required this.period,
    required this.current,
    required this.onPurchase,
    this.checkoutBlockedReason,
  });

  final V2Plan plan;
  final V2Currency currency;
  final V2BillingPeriod period;
  final bool current;
  final ValueChanged<V2PlanPurchase>? onPurchase;

  /// Set when no paid plan can be bought at all in this build.
  final String? checkoutBlockedReason;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final price = plan.amount(currency, period);
    final priceLabel = plan.priceLabel(currency, period: period);
    final productId = plan.productIdFor(period);
    final free = plan.canonicalId == 'free';
    // Free is a Play management action, not a product: it has no SKU by design.
    // Every other plan must have both a product for the selected period and a
    // price for it; without either the CTA is disabled instead of charging a
    // different period's SKU or an invented amount.
    final storePrice = plan.storePriceFor(currency, period);
    final priceKnown = price != null || storePrice != null;
    final missingProduct = !current && !free && productId == null;
    final missingPrice = !current && !free && !missingProduct && !priceKnown;
    // The store was queried and does not sell this period (e.g. the yearly
    // base plan has not been created in Play Console yet).
    final storeMissing =
        !current && !free && !missingProduct && plan.storeAvailableFor(period) == false;
    // No purchase path in this build can both take money and unlock the plan
    // (e.g. RevenueCat with no server confirmation route).
    final checkoutBlocked =
        !current && !free && checkoutBlockedReason != null;
    final unavailable =
        checkoutBlocked || missingProduct || missingPrice || storeMissing;
    final canBuy = !current && onPurchase != null && !unavailable;
    final periodWord = period == V2BillingPeriod.yearly ? 'yearly' : 'monthly';
    final reason = checkoutBlocked
        ? checkoutBlockedReason
        : missingProduct
        ? '${plan.name} is not sold with $periodWord billing right now.'
        : missingPrice
        ? 'No $periodWord price for ${plan.name}.'
        : storeMissing
        ? '$periodWord billing is not available in Google Play yet.'
        : null;
    // The card is one group for a screen reader: name and price first, then
    // the CTA (which announces its own enabled/disabled state). The name and
    // price texts are excluded so they are not read twice.
    final groupLabel = !priceKnown
        ? '${plan.name}, price unavailable'
        : '${plan.name}, $priceLabel ${plan.periodPhrase(period)}';
    // The current plan is marked with a 2 dp accent edge; the popular plan
    // keeps the soft accent tint. They never compete: current wins.
    final decoration = BoxDecoration(
      color: !current && plan.popular ? c.accentSoft : c.surface,
      borderRadius: BorderRadius.circular(ORadius.l),
      border: Border.all(
        color: current
            ? c.accentFill
            : plan.popular
            ? c.accentFill.withValues(alpha: 0.35)
            : c.hairline,
        width: current ? 2 : 1,
      ),
    );
    return Semantics(
      key: ValueKey<String>('plan-group-${plan.id}'),
      container: true,
      explicitChildNodes: true,
      label: current ? '$groupLabel, current plan' : groupLabel,
      child: Container(
        key: ValueKey<String>('plan-card-${plan.id}'),
        decoration: decoration,
        padding: const EdgeInsets.all(OSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      plan.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.h2.copyWith(color: c.text),
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        priceLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.h2.copyWith(
                          color: plan.popular ? c.accent : c.text,
                        ),
                      ),
                    ),
                    ExcludeSemantics(
                      child: Text(
                        plan.periodSuffix(period),
                        maxLines: 1,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            if (plan.tagline.isNotEmpty) ...[
              const SizedBox(height: OSpace.xs),
              Text(
                plan.tagline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
            const SizedBox(height: OSpace.l),
            OButton(
              key: ValueKey<String>('plan-cta-${plan.id}'),
              label: current
                  ? 'Current plan'
                  : unavailable
                  ? 'Not available'
                  : plan.actionLabel,
              variant: plan.popular
                  ? OButtonVariant.primary
                  : OButtonVariant.secondary,
              expand: true,
              // The current plan can never be bought again. A disabled CTA is
              // the honest state: tapping it would only re-purchase a plan the
              // account already owns.
              onPressed: canBuy
                  ? () =>
                        onPurchase!(V2PlanPurchase(plan: plan, period: period))
                  : null,
            ),
            if (reason != null) ...[
              const SizedBox(height: OSpace.xs),
              Text(
                reason,
                key: ValueKey<String>('plan-unavailable-${plan.id}'),
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `day` → 24, `3 h` → 3. Unknown copy falls back to a daily window.
int _fileWindowHours(String label) {
  if (label.trim().toLowerCase() == 'day') return 24;
  final match = RegExp(r'([0-9]+)').firstMatch(label);
  return match == null ? 24 : int.tryParse(match.group(1)!) ?? 24;
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onTap});

  final V2BillingHistoryEntry entry;
  final ValueChanged<V2BillingHistoryEntry>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // "Paid" is the quiet default. Any other verdict (refunded, failed) is
    // shown, so a row never reads as a completed payment when it is not one.
    final status = entry.statusLabel.trim();
    final showStatus = status.isNotEmpty && status.toLowerCase() != 'paid';
    return V2SettingsRow(
      icon: Icons.receipt_long_outlined,
      title: entry.title,
      subtitle: entry.dateLabel,
      showChevron: false,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            entry.amountLabel,
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (showStatus)
            Text(
              status,
              key: ValueKey<String>('payment-status-${entry.id}'),
              style: OType.caption.copyWith(color: c.textMuted),
            ),
        ],
      ),
      onTap: onTap == null ? null : () => onTap!(entry),
    );
  }
}
