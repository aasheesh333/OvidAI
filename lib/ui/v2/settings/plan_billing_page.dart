// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'plan_compare_table.dart';

enum V2PlanBillingStatus { loading, ready, empty, error }

enum V2Currency { usd, inr }

enum V2BillingPeriod { monthly, yearly }

/// The authoritative plan table from the product spec (§11). Every limit is
/// per user: storage, file intake, project size, model access and the token
/// allowance multiplier over Free.
///
/// Paid token caps are Free × the plan's auto multiplier:
/// Go 1.5×, Plus 5×, Pro 20× (50M / 24 h and 1.5B / 30 d on Free).
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
    autoMultiplier: 1.5,
    customConnectors: 5,
    dailyTokenCap: 75000000,
    monthlyTokenCap: 2250000000,
  );

  static const plus = V2PlanLimits(
    id: 'plus',
    name: 'Ovid Plus',
    storageGb: 15,
    filesPerWindow: 80,
    fileWindowLabel: '3 h',
    filesPerProject: 150,
    manualModels: true,
    autoMultiplier: 5,
    customConnectors: 20,
    dailyTokenCap: 250000000,
    monthlyTokenCap: 7500000000,
  );

  static const pro = V2PlanLimits(
    id: 'pro',
    name: 'Ovid Pro',
    storageGb: 75,
    filesPerWindow: 80,
    fileWindowLabel: '3 h',
    filesPerProject: 250,
    manualModels: true,
    autoMultiplier: 20,
    customConnectors: 20,
    dailyTokenCap: 1000000000,
    monthlyTokenCap: 30000000000,
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

  String get autoMultiplierLabel => '${formatMultiplier(autoMultiplier)}× auto';

  String get autoAllowanceLabel =>
      '${formatMultiplier(autoMultiplier)}× Free auto allowance';

  String get customConnectorsLabel => customConnectors == 0
      ? 'No custom connectors'
      : '$customConnectors custom connectors';

  String get dailyCapLabel => _groupDigits(dailyTokenCap);

  String get monthlyCapLabel => _groupDigits(monthlyTokenCap);

  String get dailyCapDescription => '$dailyCapLabel tokens / 24 h';

  String get monthlyCapDescription => '$monthlyCapLabel tokens / 30 days';
}

/// `1` → `1`, `1.5` → `1.5`, `20` → `20`.
String formatMultiplier(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

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

  int amount(V2Currency currency, V2BillingPeriod period) {
    final monthly = currency == V2Currency.inr ? priceInr : priceUsd;
    if (period == V2BillingPeriod.monthly) return monthly;
    final yearly = currency == V2Currency.inr ? priceInrYearly : priceUsdYearly;
    return yearly > 0 ? yearly : monthly * 12;
  }

  String priceLabel(
    V2Currency currency, {
    V2BillingPeriod period = V2BillingPeriod.monthly,
  }) {
    final amount = this.amount(currency, period);
    final symbol = currency == V2Currency.inr ? '₹' : r'$';
    return '$symbol${_groupDigits(amount)}';
  }

  String periodSuffix(V2BillingPeriod period) =>
      period == V2BillingPeriod.monthly ? '/ month' : '/ year';

  String get actionLabel =>
      ctaLabel ??
      (canonicalId == 'free'
          // A paid account downgrades/cancels in Play, it never "selects Free".
          ? 'Manage in Google Play'
          : popular
          ? 'Upgrade to $name'
          : 'Select $name');
}

/// The store products each plan is sold as, per billing period.
///
/// The monthly ids are the ones the Play/RevenueCat layer already verifies
/// (`kOvidPlayProducts`): Go → `ovid_plus_monthly`, Plus → `ovid_pro_monthly`,
/// Pro → `ovid_max_monthly`. The yearly ids follow the same naming so the
/// purchase request names a distinct product for the yearly toggle.
abstract final class V2PlanProducts {
  static const monthly = <String, String>{
    'go': 'ovid_plus_monthly',
    'plus': 'ovid_pro_monthly',
    'pro': 'ovid_max_monthly',
  };

  static const yearly = <String, String>{
    'go': 'ovid_plus_yearly',
    'plus': 'ovid_pro_yearly',
    'pro': 'ovid_max_yearly',
  };

  /// Canonical plan id → server/RevenueCat tier id.
  static const tiers = <String, String>{
    'free': 'free',
    'go': '3x',
    'plus': '7x',
    'pro': '15x',
  };

  static String? forPlan(String planId, V2BillingPeriod period) =>
      (period == V2BillingPeriod.yearly ? yearly : monthly)[planId];

  static String tierForPlan(String planId) => tiers[planId] ?? planId;
}

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
    this.legalNote =
        'Subscriptions renew automatically each month until canceled. '
        'You can cancel anytime from Google Play Store subscriptions.',
    this.onCurrencyChanged,
    this.onPeriodChanged,
    this.onPurchase,
    this.onRestorePurchases,
    this.onHistoryTap,
    this.onRetry,
    this.errorMessage =
        'We could not load plans. Check your connection and try again.',
  });

  final V2PlanBillingStatus status;
  final V2Currency currency;
  final V2BillingPeriod period;
  final String currentPlanId;
  final List<V2Plan> plans;
  final List<V2BillingHistoryEntry> history;
  final String legalNote;
  final ValueChanged<V2Currency>? onCurrencyChanged;
  final ValueChanged<V2BillingPeriod>? onPeriodChanged;

  /// The real purchase entry point. It receives the plan the user tapped and
  /// the period currently selected on screen, so the caller never has to guess
  /// a tier (the old screen hard-coded Plus here).
  final ValueChanged<V2PlanPurchase>? onPurchase;
  final VoidCallback? onRestorePurchases;
  final ValueChanged<V2BillingHistoryEntry>? onHistoryTap;
  final VoidCallback? onRetry;
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
      message: 'Check your connection and try again.',
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
    final c = OColors.of(context);
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
          const SizedBox(height: OSpace.l),
          OSectionHeader(label: 'Payment history', padding: EdgeInsets.zero),
          if (data.history.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OSpace.m),
              child: Text(
                'No payments yet',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var index = 0; index < data.history.length; index++) ...[
                    if (index > 0) Divider(height: 1, color: c.hairline),
                    _HistoryRow(
                      entry: data.history[index],
                      onTap: data.onHistoryTap,
                    ),
                  ],
                ],
              ),
            ),
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
            child: _CurrencyOption(
              label: 'USD (\$)',
              selected: value == V2Currency.usd,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2Currency.usd),
            ),
          ),
          Flexible(
            child: _CurrencyOption(
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

class _CurrencyOption extends StatelessWidget {
  const _CurrencyOption({
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
            child: _PeriodOption(
              label: 'Monthly',
              selected: value == V2BillingPeriod.monthly,
              onTap: onChanged == null
                  ? null
                  : () => onChanged!(V2BillingPeriod.monthly),
            ),
          ),
          Flexible(
            child: _PeriodOption(
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

class _PeriodOption extends StatelessWidget {
  const _PeriodOption({
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
  });

  final V2Plan plan;
  final V2Currency currency;
  final V2BillingPeriod period;
  final bool current;
  final ValueChanged<V2PlanPurchase>? onPurchase;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canBuy = !current && onPurchase != null;
    return OCard(
      key: ValueKey<String>('plan-card-${plan.id}'),
      accent: plan.popular || current,
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.h2.copyWith(color: c.text),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    plan.priceLabel(currency, period: period),
                    maxLines: 1,
                    style: OType.h2.copyWith(
                      color: plan.popular ? c.accent : c.text,
                    ),
                  ),
                  Text(
                    plan.periodSuffix(period),
                    maxLines: 1,
                    style: OType.caption.copyWith(color: c.textMuted),
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
            label: current ? 'Current plan' : plan.actionLabel,
            variant: plan.popular
                ? OButtonVariant.primary
                : OButtonVariant.secondary,
            expand: true,
            // The current plan can never be bought again. A disabled CTA is
            // the honest state: tapping it would only re-purchase a plan the
            // account already owns.
            onPressed: canBuy
                ? () => onPurchase!(V2PlanPurchase(plan: plan, period: period))
                : null,
          ),
        ],
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
    return OListRow(
      icon: Icons.receipt_long_outlined,
      title: entry.title,
      subtitle: entry.dateLabel,
      showChevron: false,
      trailing: Text(
        entry.amountLabel,
        style: OType.bodySm.copyWith(
          color: c.text,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: onTap == null ? null : () => onTap!(entry),
    );
  }
}
