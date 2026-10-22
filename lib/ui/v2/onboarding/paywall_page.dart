import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'purchase_banner.dart';
import 'step_progress.dart';

// TODO(l10n): move paywall copy to the ARB files.

enum V2Currency { usd, inr }

@immutable
class V2PlanOption {
  const V2PlanOption({
    required this.id,
    required this.name,
    required this.priceUsd,
    required this.priceInr,
    required this.storageGb,
    this.autoOnly = false,
    this.features = const [],
  });

  final String id;
  final String name;
  final int priceUsd;
  final int priceInr;
  final int storageGb;
  final bool autoOnly;

  /// At most three are shown; the card is a comparison, not a feature list.
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
        priceUsd: 0,
        priceInr: 0,
        storageGb: 3,
        autoOnly: true,
        features: ['3 GB storage', '50M tokens a day'],
      ),
      V2PlanOption(
        id: 'go',
        name: 'Ovid Go',
        priceUsd: 5,
        priceInr: 499,
        storageGb: 5,
        autoOnly: true,
        features: ['5 GB storage', 'Schedules'],
      ),
      V2PlanOption(
        id: 'plus',
        name: 'Ovid Plus',
        priceUsd: 18,
        priceInr: 1799,
        storageGb: 15,
        features: ['All models', '15 GB storage', 'Collaboration'],
      ),
      V2PlanOption(
        id: 'pro',
        name: 'Ovid Pro',
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

/// Last step of the tour: one header, the same footer action, and plan cards
/// that are name, price, three bullets and one badge.
class PaywallPage extends StatefulWidget {
  const PaywallPage({
    super.key,
    this.data = const V2PaywallData(),
    this.onPlanSelected,
    this.onCurrencyChanged,
    this.onStartTrial,
    this.onContinueFree,
    this.onRetry,
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
  final ValueChanged<String>? onStartTrial;

  /// Declines the upgrade and enters the app on the Free plan. This is the
  /// only handler used by the Free card's call to action.
  final VoidCallback? onContinueFree;

  final VoidCallback? onRetry;

  /// Opens the store's own subscription controls. Hidden when null.
  final VoidCallback? onManageSubscription;
  final VoidCallback? onClose;

  final V2OnboardingStepData step;

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
    final data = widget.data;
    final hasPlans = !data.loading && data.plans.isNotEmpty;
    final selectedPlan = hasPlans ? _selectedPlan(data) : null;
    final canBuy =
        selectedPlan != null &&
        (selectedPlan.isFree
            ? widget.onContinueFree != null
            : widget.onStartTrial != null);
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

    return OnboardingStepScaffold(
      step: widget.step,
      title: 'Upgrade',
      subtitle: 'Choose a plan',
      onClose: widget.onClose,
      primaryKey: const Key('paywall-trial'),
      primaryLabel: selectedPlan == null
          ? 'Continue'
          : selectedPlan.isFree
          ? 'Continue with Free'
          : data.trialDays > 0
          ? 'Start free trial'
          : 'Subscribe',
      primaryLoading: data.purchasing,
      primaryVisible: hasPlans,
      scrollable: !data.loading,
      onPrimary: !canBuy
          ? null
          : () {
              if (selectedPlan.isFree) {
                widget.onContinueFree?.call();
              } else {
                widget.onStartTrial?.call(selectedPlan.id);
              }
            },
      secondaryActions: [
        // A visible way out that does not depend on finding the close icon:
        // declining is a real, supported outcome.
        if (selectedPlan != null &&
            !selectedPlan.isFree &&
            widget.onContinueFree != null)
          OTextAction(
            key: const Key('paywall-continue-free'),
            label: 'Continue with Free',
            onPressed: data.purchasing ? null : widget.onContinueFree,
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
    V2PaywallData data,
    V2PlanOption selectedPlan,
  ) {
    final c = OColors.of(context);
    final banner = _bannerData(data, selectedPlan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: _CurrencyToggle(
            currency: _currency,
            onChanged: _selectCurrency,
          ),
        ),
        const SizedBox(height: OSpace.l),
        _PlanGrid(
          plans: data.plans,
          selectedId: selectedPlan.id,
          currency: _currency,
          onTap: _selectPlan,
        ),
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
        if (banner.status != V2PurchaseBannerStatus.hidden) ...[
          const SizedBox(height: OSpace.l),
          V2PurchaseBanner(
            data: banner,
            onRetry: widget.onRetry,
            onManageSubscription: widget.onManageSubscription,
          ),
        ],
      ],
    );
  }
}

/// One column on a phone, two columns of cards from 600 dp. A card may become
/// a grid cell; a row never becomes a column.
class _PlanGrid extends StatelessWidget {
  const _PlanGrid({
    required this.plans,
    required this.selectedId,
    required this.currency,
    required this.onTap,
  });

  final List<V2PlanOption> plans;
  final String selectedId;
  final V2Currency currency;
  final ValueChanged<String> onTap;

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
              for (var i = 0; i < plans.length; i++) ...[
                if (i > 0) const SizedBox(height: OSpace.m),
                _card(plans[i]),
              ],
            ],
          );
        }
        final itemWidth = (constraints.maxWidth - OSpace.m) / 2;
        return Wrap(
          spacing: OSpace.m,
          runSpacing: OSpace.m,
          children: [
            for (final plan in plans)
              SizedBox(width: itemWidth, child: _card(plan)),
          ],
        );
      },
    );
  }

  Widget _card(V2PlanOption plan) => _PlanCard(
    plan: plan,
    selected: plan.id == selectedId,
    currency: currency,
    onTap: () => onTap(plan.id),
  );
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
    return Semantics(
      label: [
        plan.name,
        plan.modelAccessLabel,
        '${plan.priceFor(currency)} ${plan.pricePeriod}',
      ].join(', '),
      selected: selected,
      button: true,
      enabled: true,
      onTap: onTap,
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
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(top: OSpace.xxs),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? c.accentFill : c.surfaceAlt,
                      border: Border.all(
                        color: selected ? c.accentFill : c.hairlineStrong,
                      ),
                    ),
                    child: selected
                        ? Icon(Icons.check_rounded, size: 14, color: c.onAccent)
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
                              style: OType.h3.copyWith(color: c.text),
                            ),
                            const SizedBox(height: OSpace.xs),
                            OPill(
                              key: Key('plan-access-${plan.id}'),
                              label: plan.modelAccessLabel,
                              tone: plan.autoOnly
                                  ? OPillTone.neutral
                                  : OPillTone.success,
                              icon: plan.autoOnly
                                  ? Icons.lock_outline_rounded
                                  : Icons.tune_rounded,
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              plan.priceFor(currency),
                              style: OType.h3.copyWith(
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
                            style: OType.bodySm.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// States the model access a tier actually has. Free and Go are Auto-only;
/// saying so on the card is part of the product, not decoration.
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
      enabled: true,
      onTap: onTap,
      child: OPressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(OSpace.xs),
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
