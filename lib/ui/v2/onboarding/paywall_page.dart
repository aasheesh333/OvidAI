import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'purchase_banner.dart';

// TODO(l10n): move paywall copy to the ARB files.

enum V2Currency { usd, inr }

@immutable
class V2PlanOption {
  const V2PlanOption({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.priceUsd,
    required this.priceInr,
    required this.storageGb,
    this.autoOnly = false,
    this.popular = false,
    this.features = const [],
  });

  final String id;
  final String name;
  final String subtitle;
  final int priceUsd;
  final int priceInr;
  final int storageGb;
  final bool autoOnly;
  final bool popular;
  final List<String> features;

  String priceFor(V2Currency currency) =>
      currency == V2Currency.inr ? '₹${_groupInr(priceInr)}' : '\$$priceUsd';

  /// The Free tier is the only plan that is not billed monthly.
  bool get isFree => id == 'free';

  String get pricePeriod => isFree ? 'forever' : '/ month';

  /// The canonical product table: Free and Go only run the Auto model, Plus
  /// and Pro unlock manual model choice.
  String get modelAccessLabel => autoOnly ? 'Auto only' : 'Auto + manual';
}

@immutable
class V2PaywallData {
  const V2PaywallData({
    this.plans = const [
      V2PlanOption(
        id: 'free',
        name: 'Ovid Free',
        subtitle: 'No card needed',
        priceUsd: 0,
        priceInr: 0,
        storageGb: 3,
        autoOnly: true,
        features: ['Auto model', '3 GB storage', '50M tokens a day'],
      ),
      V2PlanOption(
        id: 'go',
        name: 'Ovid Go',
        subtitle: 'Essential agent toolkit',
        priceUsd: 5,
        priceInr: 499,
        storageGb: 5,
        autoOnly: true,
        features: ['Auto model only', '5 GB storage', 'Schedules'],
      ),
      V2PlanOption(
        id: 'plus',
        name: 'Ovid Plus',
        subtitle: 'Ideal for creative builders',
        priceUsd: 18,
        priceInr: 1799,
        storageGb: 15,
        popular: true,
        features: ['All models', '15 GB storage', 'Collaboration'],
      ),
      V2PlanOption(
        id: 'pro',
        name: 'Ovid Pro',
        subtitle: 'For teams and heavy use',
        priceUsd: 99,
        priceInr: 9999,
        storageGb: 75,
        features: ['All models', '75 GB storage', 'Priority support'],
      ),
    ],
    this.selectedPlanId = 'plus',
    this.currency = V2Currency.usd,
    this.loading = false,
    this.purchasing = false,
    this.error,
    this.purchaseStatus,
    this.purchaseDetail,
    this.testModeNote,
    this.trialDays = 0,
  });

  final List<V2PlanOption> plans;
  final String selectedPlanId;
  final V2Currency currency;
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

  /// Length of the Play introductory offer, in days. Zero means no trial is
  /// configured, so the call to action must not promise one.
  final int trialDays;
}

class PaywallPage extends StatefulWidget {
  const PaywallPage({
    super.key,
    this.data = const V2PaywallData(),
    this.onPlanSelected,
    this.onCurrencyChanged,
    this.onStartTrial,
    this.onContinueFree,
    this.onComparePlans,
    this.onRetry,
    this.onManageSubscription,
    this.onClose,
  });

  final V2PaywallData data;
  final ValueChanged<String>? onPlanSelected;
  final ValueChanged<V2Currency>? onCurrencyChanged;
  final ValueChanged<String>? onStartTrial;

  /// Declines the upgrade and enters the app on the Free plan. This is the
  /// only handler used by the Free card's call to action.
  final VoidCallback? onContinueFree;

  final VoidCallback? onComparePlans;
  final VoidCallback? onRetry;

  /// Opens the store's own subscription controls. Hidden when null.
  final VoidCallback? onManageSubscription;
  final VoidCallback? onClose;

  @override
  State<PaywallPage> createState() => _PaywallPageState();
}

class _PaywallPageState extends State<PaywallPage> {
  late String _selectedPlanId = widget.data.selectedPlanId;
  late V2Currency _currency = widget.data.currency;

  @override
  void didUpdateWidget(covariant PaywallPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.selectedPlanId != oldWidget.data.selectedPlanId) {
      _selectedPlanId = widget.data.selectedPlanId;
    }
    if (widget.data.currency != oldWidget.data.currency) {
      _currency = widget.data.currency;
    }
  }

  void _selectPlan(String id) {
    if (id == _selectedPlanId) return;
    setState(() => _selectedPlanId = id);
    widget.onPlanSelected?.call(id);
  }

  void _selectCurrency(V2Currency currency) {
    if (currency == _currency) return;
    setState(() => _currency = currency);
    widget.onCurrencyChanged?.call(currency);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final Widget body;
    if (data.loading) {
      body = const OSkeletonList(rows: 6);
    } else if (data.plans.isEmpty && data.error != null) {
      body = OErrorState(
        title: 'We could not load plans',
        message: data.error!,
        onRetry: widget.onRetry,
      );
    } else if (data.plans.isEmpty) {
      body = OEmptyState(
        icon: Icons.workspace_premium_rounded,
        title: 'No plans right now',
        message: 'Keep using the Free plan, or check back in a moment.',
        action: widget.onRetry == null
            ? null
            : OButton(label: 'Try again', onPressed: widget.onRetry),
      );
    } else {
      final selectedPlan = _selectedPlan(data);
      body = _content(context, c, data, selectedPlan);
    }

    return OScaffold(
      appBar: OAppBar(
        title: 'Upgrade',
        // Paywall is a tour step, not a pushed route: the default arrow would
        // try to pop the gate itself.
        showBack: false,
        actions: [
          if (widget.onClose != null)
            OIconButton(
              icon: Icons.close_rounded,
              semanticLabel: 'Close',
              onPressed: widget.onClose,
            ),
        ],
      ),
      body: body,
    );
  }

  V2PlanOption _selectedPlan(V2PaywallData data) {
    for (final plan in data.plans) {
      if (plan.id == _selectedPlanId) return plan;
    }
    return data.plans.first;
  }

  /// One banner for every billing notice on the paywall.
  ///
  /// Explicit [V2PaywallData.purchaseStatus] wins. Otherwise the legacy
  /// [V2PaywallData.error] and [V2PaywallData.testModeNote] fields map onto
  /// the matching status, so older hosts do not lose their notice.
  V2PurchaseBannerData _bannerData(
    V2PaywallData data,
    V2PlanOption selectedPlan,
  ) {
    final status =
        data.purchaseStatus ??
        (data.error != null
            ? V2PurchaseBannerStatus.failed
            : data.testModeNote != null
            ? V2PurchaseBannerStatus.testStore
            : V2PurchaseBannerStatus.hidden);
    final detail =
        data.purchaseDetail ??
        switch (status) {
          V2PurchaseBannerStatus.failed => data.error,
          V2PurchaseBannerStatus.testStore => data.testModeNote,
          _ => null,
        };
    return V2PurchaseBannerData(
      status: status,
      planName: selectedPlan.name,
      detail: detail,
    );
  }

  Widget _content(
    BuildContext context,
    OColors c,
    V2PaywallData data,
    V2PlanOption selectedPlan,
  ) {
    final banner = _bannerData(data, selectedPlan);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Stack(
        children: [
          // The paywall hero glow is the only gradient on this screen.
          Positioned(
            top: -40,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: 280,
                  height: 200,
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        c.accent.withValues(alpha: 0.18),
                        c.accent.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    Text(
                      'TIER SELECTION',
                      style: OType.overline.copyWith(color: c.accent),
                    ),
                    _CurrencyToggle(
                      currency: _currency,
                      onChanged: _selectCurrency,
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.xl),
                const Center(child: _HeroPill(label: 'OVID PLUS')),
                const SizedBox(height: OSpace.m),
                Semantics(
                  container: true,
                  header: true,
                  child: Text(
                    'Do more with Ovid Plus',
                    textAlign: TextAlign.center,
                    style: OType.display.copyWith(color: c.text),
                  ),
                ),
                const SizedBox(height: OSpace.s),
                Text(
                  'More models, more storage and background runs up to 8 hours.',
                  textAlign: TextAlign.center,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.xl),
                OStagger(
                  children: [
                    for (final plan in data.plans)
                      Padding(
                        padding: const EdgeInsets.only(bottom: OSpace.m),
                        child: _PlanCard(
                          plan: plan,
                          selected: plan.id == selectedPlan.id,
                          currency: _currency,
                          onTap: () => _selectPlan(plan.id),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: OSpace.xs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      size: 18,
                      color: c.success,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Activates after Google Play confirms · Switch or cancel '
                        'anytime',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
                if (banner.status != V2PurchaseBannerStatus.hidden) ...[
                  const SizedBox(height: OSpace.l),
                  V2PurchaseBanner(
                    data: banner,
                    onRetry: widget.onRetry,
                    onManageSubscription: widget.onManageSubscription,
                  ),
                ],
                const SizedBox(height: OSpace.l),
                OButton(
                  key: const Key('paywall-trial'),
                  label: selectedPlan.isFree
                      ? 'Continue with Free'
                      : data.trialDays > 0
                      ? 'Start ${data.trialDays}-day free trial'
                      : 'Subscribe to ${selectedPlan.name}',
                  icon: Icons.arrow_forward_rounded,
                  expand: true,
                  loading: data.purchasing,
                  onPressed:
                      data.purchasing ||
                          (selectedPlan.isFree
                              ? widget.onContinueFree == null
                              : widget.onStartTrial == null)
                      ? null
                      : () {
                          if (selectedPlan.isFree) {
                            widget.onContinueFree!();
                          } else {
                            widget.onStartTrial!(selectedPlan.id);
                          }
                        },
                ),
                const SizedBox(height: OSpace.m),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.shop_rounded, size: 16, color: c.textMuted),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Cancel anytime. Billed securely through Google Play.',
                        textAlign: TextAlign.center,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
                // A visible way out that does not depend on finding the close
                // icon: declining is a real, supported outcome.
                if (!selectedPlan.isFree && widget.onContinueFree != null) ...[
                  const SizedBox(height: OSpace.s),
                  OButton(
                    key: const Key('paywall-continue-free'),
                    label: 'Continue with Free',
                    variant: OButtonVariant.ghost,
                    onPressed: data.purchasing ? null : widget.onContinueFree,
                  ),
                ],
                // Only shown when a real comparison destination is wired.
                if (widget.onComparePlans != null) ...[
                  const SizedBox(height: OSpace.s),
                  OButton(
                    label: 'Compare all plans',
                    variant: OButtonVariant.ghost,
                    onPressed: widget.onComparePlans,
                  ),
                ],
                const SizedBox(height: OSpace.l),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrencyToggle extends StatelessWidget {
  const _CurrencyToggle({required this.currency, required this.onChanged});

  final V2Currency currency;
  final ValueChanged<V2Currency> onChanged;

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
          Flexible(
            child: _CurrencyTab(
              key: const Key('paywall-currency-usd'),
              label: 'USD (\$)',
              semanticLabel: 'US dollars',
              selected: currency == V2Currency.usd,
              onTap: () => onChanged(V2Currency.usd),
            ),
          ),
          Flexible(
            child: _CurrencyTab(
              key: const Key('paywall-currency-inr'),
              label: 'INR (₹)',
              semanticLabel: 'Indian rupees',
              selected: currency == V2Currency.inr,
              onTap: () => onChanged(V2Currency.inr),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrencyTab extends StatelessWidget {
  const _CurrencyTab({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: semanticLabel,
      selected: selected,
      button: true,
      child: OPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
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
      ),
    );
  }
}

/// Accent pill that wraps its label instead of clipping it at large text sizes.
class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.currency,
    required this.onTap,
  });

  final V2PlanOption plan;
  final bool selected;
  final V2Currency currency;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final card = Semantics(
      label: [
        plan.name,
        if (plan.popular) 'Most popular',
        plan.modelAccessLabel,
        '${plan.priceFor(currency)} ${plan.pricePeriod}',
      ].join(', '),
      selected: selected,
      button: true,
      child: OPressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          padding: const EdgeInsets.all(OSpace.l),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surface,
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(
              color: selected
                  ? c.accentFill.withValues(alpha: 0.50)
                  : c.hairline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? c.accentFill : c.surfaceAlt,
                      border: Border.all(
                        color: selected ? c.accentFill : c.hairlineStrong,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check_rounded, size: 16, color: c.onAccent)
                        : null,
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.start,
                      spacing: OSpace.m,
                      runSpacing: OSpace.s,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              plan.name,
                              style: OType.h2.copyWith(color: c.text),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              plan.subtitle,
                              style: OType.caption.copyWith(
                                color: selected ? c.accent : c.textMuted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            _AccessPill(plan: plan, colors: c),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              plan.priceFor(currency),
                              style: OType.h2.copyWith(
                                color: selected ? c.accent : c.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              plan.pricePeriod,
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.m),
              Divider(color: c.hairline, height: 1),
              const SizedBox(height: OSpace.m),
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  for (final feature in plan.features)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OSpace.s,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? c.surface : c.surfaceAlt,
                        borderRadius: BorderRadius.circular(ORadius.s),
                        border: Border.all(color: c.hairline),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_rounded, size: 13, color: c.success),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              feature,
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (!plan.popular) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: OSpace.l),
            child: Transform.translate(
              offset: const Offset(0, 6),
              child: const _PopularBadge(),
            ),
          ),
        ),
        card,
      ],
    );
  }
}

/// States the model access a tier actually has. Free and Go are Auto-only;
/// saying so on the card is part of the product, not decoration.
class _AccessPill extends StatelessWidget {
  const _AccessPill({required this.plan, required this.colors});

  final V2PlanOption plan;
  final OColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final autoOnly = plan.autoOnly;
    return Container(
      key: Key('plan-access-${plan.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: autoOnly
            ? c.surfaceAlt
            : c.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.s),
        border: Border.all(
          color: autoOnly ? c.hairline : c.success.withValues(alpha: 0.32),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            autoOnly ? Icons.lock_outline_rounded : Icons.tune_rounded,
            size: 12,
            color: autoOnly ? c.textMuted : c.success,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              plan.modelAccessLabel,
              style: OType.caption.copyWith(
                color: autoOnly ? c.textMuted : c.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PopularBadge extends StatelessWidget {
  const _PopularBadge();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 13, color: c.onAccent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'Most popular',
              style: OType.caption.copyWith(
                color: c.onAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
