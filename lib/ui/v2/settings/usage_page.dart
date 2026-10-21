// TODO(l10n): move the English copy in this screen to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

enum V2UsageStatus { loading, ready, empty, error }

enum V2UsageRange { today, sevenDays, thirtyDays }

enum V2UsageTone { accent, success, warn }

@immutable
class V2UsageDay {
  const V2UsageDay({
    required this.id,
    required this.label,
    required this.fraction,
    this.valueLabel = '',
  });

  final String id;
  final String label;

  /// Share of the tallest bar in the chart, 0..1.
  final double fraction;
  final String valueLabel;
}

@immutable
class V2UsageModel {
  const V2UsageModel({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.percent,
    required this.tokensLabel,
    this.tone = V2UsageTone.accent,
  });

  final String id;
  final String name;
  final String subtitle;
  final int percent;
  final String tokensLabel;
  final V2UsageTone tone;
}

@immutable
class V2UsageData {
  const V2UsageData({
    this.status = V2UsageStatus.ready,
    this.dailyUsedLabel = '',
    this.dailyLimitLabel = '',
    this.dailyFraction = 0,
    this.resetLabel = '',
    this.monthlyUsedLabel = '',
    this.monthlyLimitLabel = '',
    this.monthlyFraction = 0,
    this.monthlyPercentLabel = '',
    this.billingNote = '',
    this.days = const [],
    this.selectedDayId,
    this.selectedDayLabel = '',
    this.models = const [],
    this.range = V2UsageRange.today,
    this.showFreePlanNote = true,
    this.requestsLabel = '0',
    this.imagesLabel = '0',
    this.storageUsedLabel = '0 GB',
    this.storageLimitLabel = '0 GB',
    this.storageFraction = 0,
    this.upgradeTitle = 'Need more room?',
    this.upgradeMessage = 'Upgrade for higher limits and faster models.',
    this.upgradeLabel = 'Upgrade plan',
    this.onRangeChanged,
    this.onDaySelected,
    this.onStartChat,
    this.onUpgrade,
    this.onRetry,
    this.errorMessage = 'We could not load your usage.',
  });

  final V2UsageStatus status;
  final String dailyUsedLabel;
  final String dailyLimitLabel;
  final double dailyFraction;
  final String resetLabel;
  final String monthlyUsedLabel;
  final String monthlyLimitLabel;
  final double monthlyFraction;
  final String monthlyPercentLabel;
  final String billingNote;
  final List<V2UsageDay> days;
  final String? selectedDayId;
  final String selectedDayLabel;
  final List<V2UsageModel> models;
  final V2UsageRange range;
  final bool showFreePlanNote;
  final String requestsLabel;
  final String imagesLabel;
  final String storageUsedLabel;
  final String storageLimitLabel;
  final double storageFraction;
  final String upgradeTitle;
  final String upgradeMessage;
  final String upgradeLabel;
  final ValueChanged<V2UsageRange>? onRangeChanged;
  final ValueChanged<V2UsageDay>? onDaySelected;
  final VoidCallback? onStartChat;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final String errorMessage;
}

class UsagePage extends StatelessWidget {
  const UsagePage({super.key, required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    switch (data.status) {
      case V2UsageStatus.loading:
        body = const OSkeletonList(rows: 6);
      case V2UsageStatus.error:
        body = OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2UsageStatus.empty:
        body = _emptyState(context);
      case V2UsageStatus.ready:
        body = _content(context);
    }

    return OScaffold(
      appBar: const OAppBar(title: 'Usage'),
      body: OFadeSlide(child: body),
    );
  }

  Widget _emptyState(BuildContext context) {
    return OEmptyState(
      icon: Icons.insights_rounded,
      title: 'No usage yet',
      message: 'Chat with Ovid to see your token use here.',
      action: OButton(
        label: 'Start a chat',
        icon: Icons.chat_bubble_outline_rounded,
        onPressed: data.onStartChat ?? data.onRetry,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    V2UsageDay? selectedDay;
    for (final day in data.days) {
      if (day.id == data.selectedDayId) {
        selectedDay = day;
        break;
      }
    }
    selectedDay ??= data.days.isEmpty ? null : data.days.last;
    final selectedLabel = data.selectedDayLabel.isNotEmpty
        ? data.selectedDayLabel
        : selectedDay == null
        ? ''
        : '${selectedDay.label}: ${selectedDay.valueLabel}';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DailyRingCard(data: data),
          const SizedBox(height: OSpace.m),
          _MonthlyCard(data: data),
          const SizedBox(height: OSpace.m),
          _GlanceCard(data: data),
          const SizedBox(height: OSpace.m),
          _ActivityCard(
            data: data,
            selectedDay: selectedDay,
            selectedLabel: selectedLabel,
          ),
          const SizedBox(height: OSpace.m),
          _ModelsCard(data: data),
          if (data.showFreePlanNote) ...[
            const SizedBox(height: OSpace.m),
            OCard(
              padding: const EdgeInsets.all(OSpace.l),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: c.accentSoft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Free plan uses Auto only.',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Upgraded models appear when active.',
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (data.onUpgrade != null) ...[
            const SizedBox(height: OSpace.m),
            _UpgradeCard(data: data),
          ],
        ],
      ),
    );
  }
}

class _DailyRingCard extends StatelessWidget {
  const _DailyRingCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fraction = data.dailyFraction.clamp(0.0, 1.0).toDouble();
    return OCard(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.xl,
      ),
      child: Column(
        children: [
          Semantics(
            label:
                '${data.dailyUsedLabel} of ${data.dailyLimitLabel} tokens used today',
            child: ConstrainedBox(
              // The ring keeps its 208 dp look but grows with the text scale
              // instead of clipping the labels inside it.
              constraints: const BoxConstraints(minWidth: 208, minHeight: 208),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: fraction),
                      duration: OMove.duration(context, OMotion.slow),
                      curve: OMotion.emphasized,
                      builder: (context, value, _) => Center(
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: CircularProgressIndicator(
                            value: value,
                            strokeWidth: 14,
                            strokeCap: StrokeCap.round,
                            backgroundColor: c.surfaceRaised,
                            color: c.accentFill,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(OSpace.xl),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'TOKENS TODAY',
                          textAlign: TextAlign.center,
                          style: OType.overline.copyWith(color: c.success),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Text(
                          data.dailyUsedLabel,
                          textAlign: TextAlign.center,
                          style: OType.display.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Text(
                          'of ${data.dailyLimitLabel} tokens used',
                          textAlign: TextAlign.center,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: OSpace.l),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.pill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, size: 16, color: c.accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    data.resetLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthlyCard extends StatelessWidget {
  const _MonthlyCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  Icons.calendar_month_rounded,
                  size: 19,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Monthly quota',
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      data.billingNote,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              OPill(label: data.monthlyPercentLabel, tone: OPillTone.accent),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: data.monthlyFraction, height: 8),
          const SizedBox(height: OSpace.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${data.monthlyUsedLabel} used',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  '${data.monthlyLimitLabel} limit',
                  textAlign: TextAlign.right,
                  style: OType.caption.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlanceCard extends StatelessWidget {
  const _GlanceCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'This month at a glance',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: OSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _GlanceStat(
                  label: 'Requests',
                  value: data.requestsLabel,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: OSpace.m),
                color: c.hairline,
              ),
              Expanded(
                child: _GlanceStat(label: 'Images', value: data.imagesLabel),
              ),
              Container(
                width: 1,
                height: 40,
                margin: const EdgeInsets.symmetric(horizontal: OSpace.m),
                color: c.hairline,
              ),
              Expanded(
                child: _GlanceStat(
                  label: 'Storage',
                  value: data.storageUsedLabel,
                  detail: 'of ${data.storageLimitLabel}',
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: data.storageFraction, height: 6),
        ],
      ),
    );
  }
}

class _GlanceStat extends StatelessWidget {
  const _GlanceStat({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: OType.caption.copyWith(color: c.textMuted)),
        const SizedBox(height: OSpace.xs),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.h3.copyWith(color: c.text),
        ),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Text(detail!, style: OType.caption.copyWith(color: c.textFaint)),
        ],
      ],
    );
  }
}

class _UpgradeCard extends StatelessWidget {
  const _UpgradeCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      accent: true,
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 19,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.upgradeTitle,
                      style: OType.h3.copyWith(color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.upgradeMessage,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            label: data.upgradeLabel,
            icon: Icons.workspace_premium_outlined,
            expand: true,
            onPressed: data.onUpgrade,
          ),
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.data,
    required this.selectedDay,
    required this.selectedLabel,
  });

  final V2UsageData data;
  final V2UsageDay? selectedDay;
  final String selectedLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final title = Text(
                'Activity',
                style: OType.h3.copyWith(color: c.text),
              );
              // Stack the tabs under the title on narrow screens and whenever
              // the text is scaled up, so the three segments always have room.
              final compact =
                  constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final tabs = _RangeTabs(
                value: data.range,
                onChanged: data.onRangeChanged,
                expanded: compact,
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    title,
                    const SizedBox(height: OSpace.s),
                    tabs,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: title),
                  tabs,
                ],
              );
            },
          ),
          const SizedBox(height: OSpace.m),
          if (data.days.isEmpty)
            OEmptyState(
              compact: true,
              icon: Icons.bar_chart_rounded,
              title: 'No activity yet',
              message:
                  'Your daily token use will appear after your first chat.',
              action: OButton(
                label: 'Start a chat',
                icon: Icons.chat_bubble_outline_rounded,
                onPressed: data.onStartChat,
              ),
            )
          else ...[
            SizedBox(
              height: 176,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final day in data.days)
                      _UsageBar(
                        day: day,
                        selected: day.id == selectedDay?.id,
                        onTap: data.onDaySelected,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: OSpace.m),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Selected day',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Flexible(
                    child: Text(
                      selectedLabel,
                      textAlign: TextAlign.right,
                      style: OType.caption.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.day,
    required this.selected,
    required this.onTap,
  });

  final V2UsageDay day;
  final bool selected;
  final ValueChanged<V2UsageDay>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = selected
        ? c.accentFill
        : c.accentFill.withValues(alpha: 0.45);
    final semanticsLabel = '${day.label}, ${day.valueLabel}';
    final content = SizedBox(
      key: ValueKey<String>('usage-day-${day.id}'),
      width: 48,
      height: 176,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SizedBox(
                width: 22,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(ORadius.s),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        widthFactor: 1,
                        heightFactor: day.fraction.clamp(0.02, 1.0).toDouble(),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(ORadius.s),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: OSpace.s),
          ExcludeSemantics(
            child: Text(
              day.label,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(
                color: selected ? c.accent : c.textMuted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap != null) {
      // `OPressable` already reports button + enabled; adding those flags again
      // splits the node in two, so only the selected state is added here.
      return Semantics(
        selected: selected,
        child: OPressable(
          onTap: () => onTap!(day),
          semanticLabel: semanticsLabel,
          child: content,
        ),
      );
    }
    // No `OPressable` here: a disabled bar must not advertise a tap.
    return Semantics(
      label: semanticsLabel,
      button: false,
      enabled: false,
      selected: selected,
      child: content,
    );
  }
}

class _RangeTabs extends StatelessWidget {
  const _RangeTabs({
    required this.value,
    required this.onChanged,
    this.expanded = false,
  });

  final V2UsageRange value;
  final ValueChanged<V2UsageRange>? onChanged;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final tabs = <Widget>[
      _RangeTab(
        label: 'Today',
        range: V2UsageRange.today,
        selected: value == V2UsageRange.today,
        onChanged: onChanged,
        expanded: expanded,
      ),
      _RangeTab(
        label: '7 days',
        range: V2UsageRange.sevenDays,
        selected: value == V2UsageRange.sevenDays,
        onChanged: onChanged,
        expanded: expanded,
      ),
      _RangeTab(
        label: '30 days',
        range: V2UsageRange.thirtyDays,
        selected: value == V2UsageRange.thirtyDays,
        onChanged: onChanged,
        expanded: expanded,
      ),
    ];
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final tab in tabs)
            if (expanded) Expanded(child: tab) else tab,
        ],
      ),
    );
  }
}

class _RangeTab extends StatelessWidget {
  const _RangeTab({
    required this.label,
    required this.range,
    required this.selected,
    required this.onChanged,
    required this.expanded,
  });

  final String label;
  final V2UsageRange range;
  final bool selected;
  final ValueChanged<V2UsageRange>? onChanged;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final text = Text(
      label,
      textAlign: TextAlign.center,
      style: OType.caption.copyWith(
        color: selected ? c.onAccent : c.textMuted,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    final content = AnimatedContainer(
      duration: OMotion.fast,
      curve: OMotion.standard,
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? 4 : 10,
        vertical: OSpace.s,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? c.accentFill : c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: ExcludeSemantics(child: text),
    );
    if (onChanged == null) {
      // No `OPressable` here: a disabled control must not advertise a tap.
      return Semantics(
        label: label,
        button: false,
        enabled: false,
        selected: selected,
        child: content,
      );
    }
    // `OPressable` already reports button + enabled; adding those flags again
    // splits the node in two, so only the selected state is added here.
    return Semantics(
      selected: selected,
      child: OPressable(
        onTap: () => onChanged!(range),
        semanticLabel: label,
        child: content,
      ),
    );
  }
}

class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.data});

  final V2UsageData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Usage by model',
            padding: EdgeInsets.zero,
            trailing: Text(
              data.models.length == 1
                  ? '1 model active'
                  : '${data.models.length} models active',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          const SizedBox(height: OSpace.m),
          if (data.models.isEmpty)
            OEmptyState(
              compact: true,
              icon: Icons.pie_chart_outline_rounded,
              title: 'No model use yet',
              message: 'Your model split will appear after your first chat.',
              action: OButton(
                label: 'Start a chat',
                icon: Icons.chat_bubble_outline_rounded,
                onPressed: data.onStartChat,
              ),
            )
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(ORadius.pill),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: [
                    for (final model in data.models)
                      Expanded(
                        flex: model.percent.clamp(1, 100).toInt(),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: _toneColor(c, model.tone),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: OSpace.l),
            OStagger(
              children: [
                for (final model in data.models) _ModelRow(model: model),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});

  final V2UsageModel model;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      child: Padding(
        padding: const EdgeInsets.only(bottom: OSpace.m),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _toneColor(c, model.tone),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.name,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    model.subtitle,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${model.percent}%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    model.tokensLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Color _toneColor(OColors c, V2UsageTone tone) {
  return switch (tone) {
    V2UsageTone.accent => c.accentFill,
    V2UsageTone.success => c.success,
    V2UsageTone.warn => c.warn,
  };
}
