// TODO(l10n): move the English copy in this component to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

enum V2PlanCompareStatus { ready, loading, empty, error }

/// One column of the plan comparison table.
///
/// Limits are stored as numbers instead of pre-formatted strings so the table
/// can normalise file intake to "per day" and keep token caps compact. Prices
/// are injected as copy because the caller owns the currency and billing
/// period.
@immutable
class V2PlanComparePlan {
  const V2PlanComparePlan({
    required this.id,
    required this.name,
    required this.priceLabel,
    this.pricePeriodLabel = '/ month',
    this.priceAvailable = true,
    required this.storageGb,
    required this.filesPerWindow,
    required this.fileWindowHours,
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
  final String priceLabel;
  final String pricePeriodLabel;

  /// False when this plan is not sold for the billing period the table is
  /// showing (no price, no store product). The price cell then says so instead
  /// of printing a `—` next to a period suffix.
  final bool priceAvailable;

  /// Null means the server did not describe this limit; the cell renders `—`
  /// rather than claiming zero.
  final int? storageGb;

  /// Product-spec file-intake window (50 / day on Free, 80 / 3 h on the paid
  /// plans). It is **not enforced** anywhere yet
  /// (`docs/architecture/FEATURE_GAPS.md` §4.2), so the table shows only the
  /// enforced per-project cap.
  final int? filesPerWindow;
  final int? fileWindowHours;
  final int? filesPerProject;

  /// Plus and Pro unlock manual model choice; Free and Go are Auto only.
  final bool? manualModels;

  /// Allowance over the Free auto allowance (1, 1.5, 5, 20).
  final num? autoMultiplier;
  final int? customConnectors;
  final int? dailyTokenCap;
  final int? monthlyTokenCap;

  String get storageLabel => storageGb == null ? '—' : '$storageGb GB';

  String get filesPerProjectLabel =>
      filesPerProject == null ? '—' : '$filesPerProject max';

  String get modelAccessLabel => manualModels == null
      ? '—'
      : manualModels!
      ? 'Auto + manual'
      : 'Auto only';

  String get autoMultiplierLabel =>
      autoMultiplier == null ? '—' : '${_formatNumber(autoMultiplier!)}×';

  String get customConnectorsLabel => customConnectors == null
      ? '—'
      : customConnectors == 0
      ? 'None'
      : '$customConnectors';

  String get dailyTokenCapLabel =>
      dailyTokenCap == null ? '—' : _formatTokens(dailyTokenCap!);

  String get monthlyTokenCapLabel =>
      monthlyTokenCap == null ? '—' : _formatTokens(monthlyTokenCap!);

  /// The authoritative product table, ready for a caller that has no server
  /// payload yet. Prices are the USD monthly amounts.
  static const free = V2PlanComparePlan(
    id: 'free',
    name: 'Free',
    priceLabel: r'$0',
    storageGb: 3,
    filesPerWindow: 50,
    fileWindowHours: 24,
    filesPerProject: 80,
    manualModels: false,
    autoMultiplier: 1,
    customConnectors: 0,
    dailyTokenCap: 50000000,
    monthlyTokenCap: 1500000000,
  );

  static const go = V2PlanComparePlan(
    id: 'go',
    name: 'Ovid Go',
    priceLabel: r'$5',
    storageGb: 5,
    filesPerWindow: 80,
    fileWindowHours: 3,
    filesPerProject: 100,
    manualModels: false,
    autoMultiplier: 1.5,
    customConnectors: 5,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  static const plus = V2PlanComparePlan(
    id: 'plus',
    name: 'Ovid Plus',
    priceLabel: r'$18',
    storageGb: 15,
    filesPerWindow: 80,
    fileWindowHours: 3,
    filesPerProject: 150,
    manualModels: true,
    autoMultiplier: 5,
    customConnectors: 20,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  static const pro = V2PlanComparePlan(
    id: 'pro',
    name: 'Ovid Pro',
    priceLabel: r'$99',
    storageGb: 75,
    filesPerWindow: 80,
    fileWindowHours: 3,
    filesPerProject: 250,
    manualModels: true,
    autoMultiplier: 20,
    customConnectors: 20,
    dailyTokenCap: 0,
    monthlyTokenCap: 0,
  );

  static const canonical = <V2PlanComparePlan>[free, go, plus, pro];
}

@immutable
class V2PlanCompareData {
  const V2PlanCompareData({
    this.status = V2PlanCompareStatus.ready,
    this.plans = const [],
    this.currentPlanId,
    this.errorMessage =
        'Plan details could not load. Check your connection and try again.',
    this.onRetry,
  });

  final V2PlanCompareStatus status;
  final List<V2PlanComparePlan> plans;
  final String? currentPlanId;
  final String errorMessage;
  final VoidCallback? onRetry;
}

/// A side-by-side comparison of plan limits that stays readable on a 320 dp
/// phone at 200 % text.
///
/// The first column is pinned: it keeps its screen position while the plan
/// columns scroll horizontally underneath it, so a value is never separated
/// from its row label. The current plan's whole column is tinted and its header
/// carries a "Current" badge.
class PlanCompareTable extends StatefulWidget {
  const PlanCompareTable({
    super.key,
    required this.data,
    this.labelColumnWidth = 128,
    this.planColumnWidth = 152,
  });

  final V2PlanCompareData data;

  /// Width of the pinned row-label column. It is capped at half the available
  /// width on very narrow layouts.
  final double labelColumnWidth;

  /// Minimum width of a plan column. Columns grow to fill wider screens.
  final double planColumnWidth;

  @override
  State<PlanCompareTable> createState() => _PlanCompareTableState();
}

class _PlanCompareTableState extends State<PlanCompareTable> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    switch (data.status) {
      case V2PlanCompareStatus.loading:
        return _stateCard(
          const SizedBox(height: 280, child: OSkeletonList(rows: 4)),
        );
      case V2PlanCompareStatus.error:
        return _stateCard(
          OErrorState(message: data.errorMessage, onRetry: data.onRetry),
        );
      case V2PlanCompareStatus.empty:
        return _emptyCard(context);
      case V2PlanCompareStatus.ready:
        if (data.plans.isEmpty) return _emptyCard(context);
        return _table(context, data.plans);
    }
  }

  Widget _stateCard(Widget child) {
    return OCard(
      key: const ValueKey<String>('plan-compare-table'),
      padding: EdgeInsets.zero,
      child: child,
    );
  }

  Widget _emptyCard(BuildContext context) {
    return OCard(
      key: const ValueKey<String>('plan-compare-table'),
      child: OEmptyState(
        compact: true,
        icon: Icons.compare_arrows_rounded,
        title: 'No plans to compare',
        message: 'Plan details appear here.',
        action: widget.data.onRetry == null
            ? null
            : OButton(
                label: 'Check plans again',
                icon: Icons.refresh_rounded,
                onPressed: widget.data.onRetry,
              ),
      ),
    );
  }

  Widget _table(BuildContext context, List<V2PlanComparePlan> plans) {
    final currentId = widget.data.currentPlanId;

    return Semantics(
      container: true,
      label: 'Plan comparison table',
      child: OCard(
        key: const ValueKey<String>('plan-compare-table'),
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ORadius.l),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final half = constraints.maxWidth * 0.5;
              final labelWidth = widget.labelColumnWidth > half
                  ? half
                  : widget.labelColumnWidth;
              final viewport = constraints.maxWidth - labelWidth;
              var columnWidth = widget.planColumnWidth;
              final even = viewport / plans.length;
              if (even > columnWidth) columnWidth = even;
              final contentWidth = columnWidth * plans.length;
              final maxOffset = contentWidth > viewport
                  ? contentWidth - viewport
                  : 0.0;

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SingleChildScrollView(
                    key: const ValueKey<String>('plan-compare-scroll'),
                    controller: _controller,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: labelWidth + contentWidth,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _headerRow(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'storage',
                            label: 'Storage',
                            semanticLabel: 'Storage',
                            value: (plan) => _text(plan.storageLabel),
                            semanticValue: (plan) =>
                                '${plan.storageLabel} of cloud storage',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'project',
                            label: 'Files / project',
                            semanticLabel: 'Files per project',
                            value: (plan) => _text(plan.filesPerProjectLabel),
                            semanticValue: (plan) =>
                                '${plan.filesPerProject} files maximum per '
                                'project',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'models',
                            label: 'Model access',
                            semanticLabel: 'Model access',
                            value: (plan) => _modelsCell(context, plan),
                            semanticValue: (plan) => plan.manualModels == null
                                ? 'not reported'
                                : plan.manualModels!
                                ? 'Auto and manual models'
                                : 'Auto only, manual models are not available',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'auto',
                            label: 'Allowance multiplier',
                            semanticLabel: 'Allowance multiplier',
                            value: (plan) => _text(
                              plan.autoMultiplierLabel,
                              style: OType.label,
                            ),
                            semanticValue: (plan) =>
                                '${plan.autoMultiplierLabel} the Free '
                                'allowance',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'connectors',
                            label: 'Custom connectors',
                            semanticLabel: 'Custom connectors',
                            value: (plan) => _text(
                              plan.customConnectorsLabel,
                              muted:
                                  plan.customConnectors == null ||
                                  plan.customConnectors == 0,
                            ),
                            semanticValue: (plan) =>
                                plan.customConnectors == null
                                ? 'not reported'
                                : plan.customConnectors == 0
                                ? 'No custom connectors'
                                : '${plan.customConnectors} custom connectors',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'tokens',
                            label: 'Token caps',
                            semanticLabel: 'Token caps',
                            value: (plan) => _tokensCell(context, plan),
                            semanticValue: (plan) => plan.dailyTokenCap == null
                                ? 'not reported'
                                : plan.dailyTokenCap! <= 0
                                ? 'No token cap'
                                : '${plan.dailyTokenCapLabel} tokens per 24 hours, '
                                      '${plan.monthlyTokenCapLabel} tokens per 30 days',
                          ),
                          _row(
                            context,
                            plans,
                            currentId,
                            labelWidth,
                            columnWidth,
                            maxOffset,
                            id: 'price',
                            label: 'Price',
                            semanticLabel: 'Price',
                            value: (plan) => _priceCell(context, plan),
                            semanticValue: (plan) => plan.priceAvailable
                                ? '${plan.priceLabel} ${plan.pricePeriodLabel}'
                                : 'not sold for this billing period',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _headerRow(
    BuildContext context,
    List<V2PlanComparePlan> plans,
    String? currentId,
    double labelWidth,
    double columnWidth,
    double maxOffset,
  ) {
    final c = OColors.of(context);
    final currentIndex = _currentIndex(plans, currentId);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: c.surfaceAlt)),
        if (currentIndex != null)
          Positioned(
            left: labelWidth + columnWidth * currentIndex,
            top: 0,
            bottom: 0,
            width: columnWidth,
            child: Container(
              key: ValueKey<String>(
                'plan-compare-current-${plans[currentIndex].id}',
              ),
              decoration: BoxDecoration(
                color: c.accentSoft,
                border: Border(top: BorderSide(color: c.accentFill, width: 2)),
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: labelWidth),
            for (var index = 0; index < plans.length; index++)
              SizedBox(
                width: columnWidth,
                child: _headerCell(
                  context,
                  plans[index],
                  current: index == currentIndex,
                ),
              ),
          ],
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: labelWidth,
          child: _pinnedLabel(
            context,
            label: 'Plan',
            semanticLabel: 'Plan',
            key: const ValueKey<String>('plan-compare-label-plan'),
            header: true,
            maxOffset: maxOffset,
          ),
        ),
      ],
    );
  }

  Widget _headerCell(
    BuildContext context,
    V2PlanComparePlan plan, {
    required bool current,
  }) {
    final c = OColors.of(context);
    // A column header is a heading, not a control: it is not selectable, so it
    // must not publish the selected flag. The current column stays announced
    // in the label.
    return Semantics(
      key: ValueKey<String>('plan-compare-header-${plan.id}'),
      container: true,
      header: true,
      label: current ? '${plan.name}, current plan' : plan.name,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.all(OSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                plan.name,
                style: OType.h3.copyWith(color: current ? c.accent : c.text),
              ),
              if (current) ...[
                const SizedBox(height: OSpace.xs),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: OSpace.iconGap,
                  runSpacing: OSpace.xxs,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: c.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      'Current',
                      style: OType.caption.copyWith(
                        color: c.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    List<V2PlanComparePlan> plans,
    String? currentId,
    double labelWidth,
    double columnWidth,
    double maxOffset, {
    required String id,
    required String label,
    required String semanticLabel,
    required Widget Function(V2PlanComparePlan plan) value,
    required String Function(V2PlanComparePlan plan) semanticValue,
  }) {
    final c = OColors.of(context);
    final currentIndex = _currentIndex(plans, currentId);
    return Stack(
      children: [
        if (currentIndex != null)
          Positioned(
            left: labelWidth + columnWidth * currentIndex,
            top: 0,
            bottom: 0,
            width: columnWidth,
            child: ColoredBox(color: c.accentSoft),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: labelWidth),
            for (final plan in plans)
              SizedBox(
                width: columnWidth,
                child: Semantics(
                  key: ValueKey<String>('plan-compare-cell-${plan.id}-$id'),
                  container: true,
                  label: '${plan.name}, $semanticLabel: ${semanticValue(plan)}',
                  child: ExcludeSemantics(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OSpace.m,
                        vertical: OSpace.m,
                      ),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: c.hairline)),
                      ),
                      child: value(plan),
                    ),
                  ),
                ),
              ),
          ],
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: labelWidth,
          child: _pinnedLabel(
            context,
            label: label,
            semanticLabel: semanticLabel,
            key: ValueKey<String>('plan-compare-label-$id'),
            maxOffset: maxOffset,
          ),
        ),
      ],
    );
  }

  Widget _pinnedLabel(
    BuildContext context, {
    required String label,
    required String semanticLabel,
    required Key key,
    bool header = false,
    double maxOffset = 0,
  }) {
    final c = OColors.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final raw = _controller.hasClients ? _controller.offset : 0.0;
        final offset = raw < 0 ? 0.0 : (raw > maxOffset ? maxOffset : raw);
        return Transform.translate(offset: Offset(offset, 0), child: child);
      },
      child: Semantics(
        key: key,
        container: true,
        label: semanticLabel,
        child: ExcludeSemantics(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.m,
            ),
            decoration: BoxDecoration(
              color: header ? c.surfaceAlt : c.surface,
              border: Border(
                top: header ? BorderSide.none : BorderSide(color: c.hairline),
                right: BorderSide(color: c.hairlineStrong),
              ),
            ),
            child: Text(
              label,
              style: (header ? OType.overline : OType.label).copyWith(
                color: c.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _text(String value, {TextStyle? style, bool muted = false}) {
    final c = OColors.of(context);
    return Text(
      value,
      style: (style ?? OType.caption).copyWith(
        color: muted ? c.textMuted : c.text,
        fontWeight: style == null ? FontWeight.w500 : null,
      ),
    );
  }

  Widget _modelsCell(BuildContext context, V2PlanComparePlan plan) {
    final c = OColors.of(context);
    final manual = plan.manualModels;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          manual == null
              ? Icons.remove_rounded
              : manual
              ? Icons.check_circle_outline_rounded
              : Icons.lock_outline_rounded,
          size: 14,
          color: manual == true ? c.success : c.textFaint,
        ),
        const SizedBox(width: OSpace.iconGap),
        Expanded(
          child: Text(
            plan.modelAccessLabel,
            style: OType.caption.copyWith(
              color: manual == true ? c.text : c.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tokensCell(BuildContext context, V2PlanComparePlan plan) {
    final c = OColors.of(context);
    // An unreported cap is unknown, not "no cap" and not zero.
    if (plan.dailyTokenCap == null) {
      return Text('—', style: OType.caption.copyWith(color: c.textMuted));
    }
    // Paid plans are not token-capped (server/mint/ovid_plans.py); a zero cap
    // means "no cap", not a zero allowance.
    if (plan.dailyTokenCap! <= 0) {
      return Text(
        'No token cap',
        style: OType.caption.copyWith(color: c.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${plan.dailyTokenCapLabel} / 24 h',
          style: OType.caption.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: OSpace.xxs),
        Text(
          '${plan.monthlyTokenCapLabel} / 30 d',
          style: OType.caption.copyWith(color: c.textMuted),
        ),
      ],
    );
  }

  Widget _priceCell(BuildContext context, V2PlanComparePlan plan) {
    final c = OColors.of(context);
    final current = _matches(plan, widget.data.currentPlanId);
    if (!plan.priceAvailable) {
      return Text(
        'Not sold',
        style: OType.caption.copyWith(color: c.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          plan.priceLabel,
          style: OType.h3.copyWith(color: current ? c.accent : c.text),
        ),
        const SizedBox(height: OSpace.xxs),
        Text(
          plan.pricePeriodLabel,
          style: OType.caption.copyWith(color: c.textMuted),
        ),
      ],
    );
  }

  /// The current plan can be named by its id (`plus`) or its display name
  /// (`Ovid Plus`); both resolve to the same column.
  static bool _matches(V2PlanComparePlan plan, String? currentId) {
    if (currentId == null) return false;
    final id = currentId.trim().toLowerCase();
    return plan.id.trim().toLowerCase() == id ||
        plan.name.trim().toLowerCase() == id;
  }

  static int? _currentIndex(List<V2PlanComparePlan> plans, String? currentId) {
    if (currentId == null) return null;
    for (var index = 0; index < plans.length; index++) {
      if (_matches(plans[index], currentId)) return index;
    }
    return null;
  }
}

String _formatNumber(num value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

String _formatTokens(int value) {
  if (value >= 1000000000) return '${_formatNumber(value / 1000000000)}B';
  if (value >= 1000000) return '${_formatNumber(value / 1000000)}M';
  return '$value';
}
