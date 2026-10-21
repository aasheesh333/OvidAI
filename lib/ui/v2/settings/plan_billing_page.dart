// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

enum V2PlanBillingStatus { loading, ready, empty, error }

enum V2Currency { usd, inr }

enum V2BillingPeriod { monthly, yearly }

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
  final List<String> features;
  final bool popular;
  final String? ctaLabel;

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
      ctaLabel ?? (popular ? 'Upgrade to $name' : 'Select $name');
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
    this.currentCtaLabel = 'Upgrade to Pro',
    this.legalNote =
        'Subscriptions renew automatically each month until canceled. '
        'You can cancel anytime from Google Play Store subscriptions.',
    this.onCurrencyChanged,
    this.onPeriodChanged,
    this.onSelectPlan,
    this.onUpgrade,
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
  final String currentCtaLabel;
  final String legalNote;
  final ValueChanged<V2Currency>? onCurrencyChanged;
  final ValueChanged<V2BillingPeriod>? onPeriodChanged;
  final ValueChanged<V2Plan>? onSelectPlan;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRestorePurchases;
  final ValueChanged<V2BillingHistoryEntry>? onHistoryTap;
  final VoidCallback? onRetry;
  final String errorMessage;
}

class PlanBillingPage extends StatelessWidget {
  const PlanBillingPage({super.key, required this.data});

  final V2PlanBillingData data;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2PlanBillingStatus.loading:
        body = const OSkeletonList(rows: 5);
      case V2PlanBillingStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2PlanBillingStatus.empty:
        body = _emptyState(context);
      case V2PlanBillingStatus.ready:
        body = data.plans.isEmpty ? _emptyState(context) : _content(context);
    }

    return OScaffold(
      appBar: const OAppBar(title: 'Plan & billing'),
      body: OFadeSlide(child: body),
    );
  }

  Widget _emptyState(BuildContext context) {
    return OEmptyState(
      icon: Icons.sell_outlined,
      title: 'No plans to show',
      message: 'Check your connection and try again.',
      action: OButton(
        label: 'Check plans again',
        icon: Icons.refresh_rounded,
        onPressed: data.onRetry,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    V2Plan? current;
    for (final plan in data.plans) {
      if (plan.id == data.currentPlanId) {
        current = plan;
        break;
      }
    }
    final upgrades = data.plans
        .where((plan) => plan.id != current?.id)
        .toList(growable: false);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.l,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'ACCOUNT TIER',
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.m,
            runSpacing: OSpace.s,
            crossAxisAlignment: WrapCrossAlignment.center,
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
          if (current != null) ...[
            const SizedBox(height: OSpace.l),
            _CurrentPlanCard(
              plan: current,
              currency: data.currency,
              period: data.period,
              ctaLabel: data.currentCtaLabel,
              onUpgrade: data.onUpgrade,
            ),
          ],
          if (upgrades.isNotEmpty) ...[
            const SizedBox(height: OSpace.xl),
            OSectionHeader(
              label: 'Available upgrades',
              padding: EdgeInsets.zero,
              trailing: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt_rounded, size: 15, color: c.accent),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        'Instant activation',
                        textAlign: TextAlign.end,
                        style: OType.caption.copyWith(color: c.accent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: OSpace.m),
            OStagger(
              children: [
                for (final plan in upgrades)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OSpace.m),
                    child: _PlanCard(
                      plan: plan,
                      currency: data.currency,
                      period: data.period,
                      onSelect: data.onSelectPlan,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: OSpace.l),
          Center(
            child: OButton(
              label: 'Restore purchases',
              icon: Icons.restore_rounded,
              variant: OButtonVariant.ghost,
              onPressed: data.onRestorePurchases,
            ),
          ),
          const SizedBox(height: OSpace.xl),
          OSectionHeader(
            label: 'Payment history',
            padding: EdgeInsets.zero,
            trailing: data.history.isEmpty
                ? null
                : Text(
                    data.history.length == 1
                        ? '1 payment'
                        : '${data.history.length} payments',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
          ),
          const SizedBox(height: OSpace.m),
          if (data.history.isEmpty)
            OCard(
              child: OEmptyState(
                compact: true,
                icon: Icons.receipt_long_outlined,
                title: 'No payments yet',
                message: 'Your receipts will appear here after you upgrade.',
                action: data.onUpgrade == null
                    ? null
                    : OButton(
                        label: 'See plans',
                        icon: Icons.arrow_upward_rounded,
                        onPressed: data.onUpgrade,
                      ),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: OStagger(
                children: [
                  for (var index = 0; index < data.history.length; index++)
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _HistoryRow(
                          entry: data.history[index],
                          onTap: data.onHistoryTap,
                        ),
                        if (index != data.history.length - 1)
                          Divider(
                            height: 1,
                            thickness: 1,
                            indent: 64,
                            color: c.hairline,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          const SizedBox(height: OSpace.l),
          Text(
            data.legalNote,
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
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

class _CurrentPlanCard extends StatelessWidget {
  const _CurrentPlanCard({
    required this.plan,
    required this.currency,
    required this.period,
    required this.ctaLabel,
    required this.onUpgrade,
  });

  final V2Plan plan;
  final V2Currency currency;
  final V2BillingPeriod period;
  final String ctaLabel;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: OPill(
              label: 'Current plan',
              tone: OPillTone.success,
              dot: true,
            ),
          ),
          const SizedBox(height: OSpace.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(plan.name, style: OType.h2.copyWith(color: c.text)),
              ),
              const SizedBox(width: OSpace.m),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    plan.priceLabel(currency, period: period),
                    style: OType.h2.copyWith(color: c.text),
                  ),
                  Text(
                    plan.periodSuffix(period),
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          _PlanMeta(plan: plan),
          if (plan.features.isNotEmpty) const SizedBox(height: OSpace.s),
          for (final feature in plan.features)
            _FeatureLine(
              label: feature,
              icon: Icons.check_circle_rounded,
              color: c.success,
            ),
          if (onUpgrade != null) ...[
            const SizedBox(height: OSpace.s),
            OButton(
              label: ctaLabel,
              expand: true,
              trailing: const Icon(Icons.arrow_downward_rounded, size: 18),
              onPressed: onUpgrade,
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.currency,
    required this.period,
    required this.onSelect,
  });

  final V2Plan plan;
  final V2Currency currency;
  final V2BillingPeriod period;
  final ValueChanged<V2Plan>? onSelect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      accent: plan.popular,
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (plan.popular) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: OPill(label: 'Most popular', tone: OPillTone.accent),
            ),
            const SizedBox(height: OSpace.m),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plan.name, style: OType.h2.copyWith(color: c.text)),
                    if (plan.tagline.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        plan.tagline,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: OSpace.m),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    plan.priceLabel(currency, period: period),
                    style: OType.h2.copyWith(
                      color: plan.popular ? c.accent : c.text,
                    ),
                  ),
                  Text(
                    plan.periodSuffix(period),
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          _PlanMeta(plan: plan),
          if (plan.features.isNotEmpty) const SizedBox(height: OSpace.s),
          for (final feature in plan.features)
            _FeatureLine(
              label: feature,
              icon: plan.popular ? Icons.verified_rounded : Icons.check_rounded,
              color: plan.popular ? c.accent : c.success,
            ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: plan.actionLabel,
            variant: plan.popular
                ? OButtonVariant.primary
                : OButtonVariant.secondary,
            expand: true,
            onPressed: onSelect == null ? null : () => onSelect!(plan),
          ),
        ],
      ),
    );
  }
}

class _PlanMeta extends StatelessWidget {
  const _PlanMeta({required this.plan});

  final V2Plan plan;

  @override
  Widget build(BuildContext context) {
    if (plan.storageGb <= 0 && !plan.autoOnly) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.s,
      children: [
        if (plan.storageGb > 0) OPill(label: '${plan.storageGb} GB storage'),
        if (plan.autoOnly) const OPill(label: 'Auto only'),
      ],
    );
  }
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
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            entry.amountLabel,
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          OPill(label: entry.statusLabel, tone: OPillTone.success, dot: true),
        ],
      ),
      onTap: onTap == null ? null : () => onTap!(entry),
    );
  }
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              label,
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
