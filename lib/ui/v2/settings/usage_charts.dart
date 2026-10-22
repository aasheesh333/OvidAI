// TODO(l10n): move the English copy in these charts to the ARB files.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// Shared lifecycle for every chart. Charts are presentational: the adapter
/// owns fetching and hands the chart one immutable state at a time.
enum V2UsageChartStatus { ready, loading, empty, error }

/// Token history window. The caller supplies the matching points; the chart
/// only renders and reports the selected window.
enum V2UsageChartRange { sevenDays, thirtyDays }

extension V2UsageChartRangeCopy on V2UsageChartRange {
  String get label => switch (this) {
    V2UsageChartRange.sevenDays => 'Last 7 days',
    V2UsageChartRange.thirtyDays => 'Last 30 days',
  };
}

@immutable
class V2TokenChartPoint {
  const V2TokenChartPoint({
    required this.id,
    required this.label,
    required this.value,
    this.valueLabel = '',
  });

  final String id;

  /// Short axis label, e.g. `Mon` or `Sep 22`.
  final String label;

  /// Absolute token count for this day.
  final double value;

  /// Pre-formatted value for the a11y summary, e.g. `8.2M tokens`.
  final String valueLabel;
}

@immutable
class V2ModelShareSlice {
  const V2ModelShareSlice({
    required this.id,
    required this.label,
    required this.percent,
    this.valueLabel = '',
  });

  final String id;
  final String label;

  /// Share of the period's tokens, 0..100. Shares are normalised for the
  /// painted bar, so callers may round them without losing the split.
  final double percent;

  /// Pre-formatted volume, e.g. `9.6M tokens`.
  final String valueLabel;
}

@immutable
class V2ImageUsagePoint {
  const V2ImageUsagePoint({
    required this.id,
    required this.label,
    required this.count,
    this.valueLabel = '',
  });

  final String id;
  final String label;
  final int count;
  final String valueLabel;
}

/// Daily token bars with a 7/30 day switch.
///
/// No card, no axis labels, no legend: the range switch sits above the bars
/// and the bars are the whole chart. The a11y summary on the painted area
/// carries the numbers a screen reader needs.
class V2DailyTokensChart extends StatelessWidget {
  const V2DailyTokensChart({
    super.key,
    this.points = const [],
    this.range = V2UsageChartRange.sevenDays,
    this.status = V2UsageChartStatus.ready,
    this.emptyTitle = 'No token activity yet',
    this.emptyMessage =
        'Your daily token use will appear after your first chat.',
    this.errorMessage = 'We could not load your token activity.',
    this.onRangeChanged,
    this.onStartChat,
    this.onRetry,
  });

  final List<V2TokenChartPoint> points;
  final V2UsageChartRange range;
  final V2UsageChartStatus status;
  final String emptyTitle;
  final String emptyMessage;
  final String errorMessage;
  final ValueChanged<V2UsageChartRange>? onRangeChanged;
  final VoidCallback? onStartChat;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final total = points.fold<double>(0, (sum, point) => sum + point.value);
    final hasData =
        status == V2UsageChartStatus.ready && points.isNotEmpty && total > 0;
    // Keep the range switch reachable on an empty window: the 7 day view can
    // be empty while the 30 day ledger has activity, and hiding the only
    // control would trap the reader in the empty state.
    final showRange =
        (status == V2UsageChartStatus.ready ||
            status == V2UsageChartStatus.empty) &&
        (hasData || onRangeChanged != null);

    final Widget body;
    switch (status) {
      case V2UsageChartStatus.loading:
        body = const _ChartSkeleton();
      case V2UsageChartStatus.error:
        body = OErrorState(message: errorMessage, onRetry: onRetry);
      case V2UsageChartStatus.empty:
        body = _empty();
      case V2UsageChartStatus.ready:
        body = hasData ? _chart(context) : _empty();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showRange) ...[
          // The 7/30 switch: right-aligned normally, full-width when the
          // text scale would overflow a trailing pill row.
          LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final tabs = _ChartRangeTabs(
                value: range,
                onChanged: onRangeChanged,
                expanded: compact,
              );
              return compact
                  ? tabs
                  : Align(alignment: Alignment.centerRight, child: tabs);
            },
          ),
          const SizedBox(height: OSpace.m),
        ],
        body,
      ],
    );
  }

  Widget _empty() {
    return OEmptyState(
      compact: true,
      icon: Icons.bar_chart_rounded,
      title: emptyTitle,
      message: emptyMessage,
      action: _emptyAction(onStartChat: onStartChat, onRetry: onRetry),
    );
  }

  Widget _chart(BuildContext context) {
    final c = OColors.of(context);
    var peak = points.first;
    var lowest = points.first;
    for (final point in points) {
      if (point.value > peak.value) peak = point;
      if (point.value < lowest.value) lowest = point;
    }
    final summary =
        'Daily tokens chart, ${range.label.toLowerCase()}. '
        '${_compactNumber(points.fold<double>(0, (sum, p) => sum + p.value))} '
        'tokens total. Peak ${peak.label}, ${_pointValue(peak)}. '
        'Lowest ${lowest.label}, ${_pointValue(lowest)}.';

    return Semantics(
      key: const ValueKey<String>('usage-chart-daily'),
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 168,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: OMove.duration(context, OMotion.base),
            curve: OMotion.emphasized,
            builder: (context, progress, _) => CustomPaint(
              painter: _TokenBarsPainter(
                values: [for (final point in points) point.value],
                maxValue: points.fold<double>(
                  0,
                  (max, point) => math.max(max, point.value),
                ),
                barColor: c.accentFill,
                baselineColor: c.hairlineStrong,
                progress: progress,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 100% stacked share bar plus a readable legend.
class V2ModelShareChart extends StatelessWidget {
  const V2ModelShareChart({
    super.key,
    this.slices = const [],
    this.status = V2UsageChartStatus.ready,
    this.title = 'Usage by model',
    this.emptyTitle = 'No model use yet',
    this.emptyMessage = 'Your model split will appear after your first chat.',
    this.errorMessage = 'We could not load your model usage.',
    this.onStartChat,
    this.onRetry,
  });

  final List<V2ModelShareSlice> slices;
  final V2UsageChartStatus status;
  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final String errorMessage;
  final VoidCallback? onStartChat;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final total = slices.fold<double>(0, (sum, slice) => sum + slice.percent);
    final hasData =
        status == V2UsageChartStatus.ready && slices.isNotEmpty && total > 0;

    final Widget body;
    switch (status) {
      case V2UsageChartStatus.loading:
        body = const _ChartSkeleton();
      case V2UsageChartStatus.error:
        body = OErrorState(message: errorMessage, onRetry: onRetry);
      case V2UsageChartStatus.empty:
        body = _empty();
      case V2UsageChartStatus.ready:
        body = hasData ? _chart(context) : _empty();
    }

    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChartHeader(
            title: title,
            subtitle: 'Share of tokens',
            trailing: hasData
                ? OPill(
                    label: slices.length == 1
                        ? '1 model'
                        : '${slices.length} models',
                    tone: OPillTone.accent,
                  )
                : null,
          ),
          const SizedBox(height: OSpace.m),
          body,
        ],
      ),
    );
  }

  Widget _empty() {
    return OEmptyState(
      compact: true,
      icon: Icons.pie_chart_outline_rounded,
      title: emptyTitle,
      message: emptyMessage,
      action: _emptyAction(onStartChat: onStartChat, onRetry: onRetry),
    );
  }

  Widget _chart(BuildContext context) {
    final c = OColors.of(context);
    final colors = [for (var i = 0; i < slices.length; i++) _sliceColor(c, i)];
    final shown = slices
        .take(6)
        .map((slice) => '${slice.label} ${_percentLabel(slice.percent)}');
    final hidden = slices.length - 6;
    final summary =
        'Model share chart. ${shown.join(', ')}'
        '${hidden > 0 ? ', and $hidden more' : ''}.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          key: const ValueKey<String>('usage-chart-model-share'),
          container: true,
          label: summary,
          child: ExcludeSemantics(
            child: SizedBox(
              height: 16,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: OMove.duration(context, OMotion.slow),
                curve: OMotion.emphasized,
                builder: (context, progress, _) => CustomPaint(
                  painter: _ShareBarPainter(
                    percents: [for (final slice in slices) slice.percent],
                    colors: colors,
                    trackColor: c.surfaceRaised,
                    progress: progress,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: OSpace.m),
        for (final entry in slices.asMap().entries)
          _ModelLegendRow(slice: entry.value, color: colors[entry.key]),
      ],
    );
  }
}

/// Daily image generations drawn as a line with a soft area fill.
class V2ImageUsageChart extends StatelessWidget {
  const V2ImageUsageChart({
    super.key,
    this.points = const [],
    this.status = V2UsageChartStatus.ready,
    this.title = 'Images generated',
    this.emptyTitle = 'No images yet',
    this.emptyMessage = 'Images you generate will show up here.',
    this.errorMessage = 'We could not load your image usage.',
    this.onStartChat,
    this.onRetry,
  });

  final List<V2ImageUsagePoint> points;
  final V2UsageChartStatus status;
  final String title;
  final String emptyTitle;
  final String emptyMessage;
  final String errorMessage;
  final VoidCallback? onStartChat;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final total = points.fold<int>(0, (sum, point) => sum + point.count);
    final hasData =
        status == V2UsageChartStatus.ready && points.isNotEmpty && total > 0;

    final Widget body;
    switch (status) {
      case V2UsageChartStatus.loading:
        body = const _ChartSkeleton();
      case V2UsageChartStatus.error:
        body = OErrorState(message: errorMessage, onRetry: onRetry);
      case V2UsageChartStatus.empty:
        body = _empty();
      case V2UsageChartStatus.ready:
        body = hasData ? _chart(context) : _empty();
    }

    return OCard(
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ChartHeader(
            title: title,
            subtitle: 'Per day',
            trailing: hasData
                ? _ChartTotal(
                    value: '$total',
                    caption: total == 1 ? 'image' : 'images',
                  )
                : null,
          ),
          const SizedBox(height: OSpace.m),
          body,
        ],
      ),
    );
  }

  Widget _empty() {
    return OEmptyState(
      compact: true,
      icon: Icons.image_outlined,
      title: emptyTitle,
      message: emptyMessage,
      action: _emptyAction(onStartChat: onStartChat, onRetry: onRetry),
    );
  }

  Widget _chart(BuildContext context) {
    final c = OColors.of(context);
    var peak = points.first;
    for (final point in points) {
      if (point.count > peak.count) peak = point;
    }
    final total = points.fold<int>(0, (sum, point) => sum + point.count);
    final summary =
        'Image usage chart, ${points.length} '
        '${points.length == 1 ? 'day' : 'days'}. $total '
        '${total == 1 ? 'image' : 'images'} total. '
        'Peak ${peak.label}, ${peak.count} '
        '${peak.count == 1 ? 'image' : 'images'}.';

    return Semantics(
      key: const ValueKey<String>('usage-chart-images'),
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 152,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: OMove.duration(context, OMotion.slow),
                curve: OMotion.emphasized,
                builder: (context, progress, _) => CustomPaint(
                  painter: _ImageLinePainter(
                    values: [
                      for (final point in points) point.count.toDouble(),
                    ],
                    maxValue: points.fold<double>(
                      0,
                      (max, point) => math.max(max, point.count.toDouble()),
                    ),
                    lineColor: c.accentFill,
                    fillColor: c.accentFill.withValues(alpha: 0.14),
                    gridColor: c.hairline,
                    baselineColor: c.hairlineStrong,
                    progress: progress,
                  ),
                ),
              ),
            ),
            const SizedBox(height: OSpace.s),
            _ChartAxis(labels: [for (final point in points) point.label]),
          ],
        ),
      ),
    );
  }
}

class _ChartHeader extends StatelessWidget {
  const _ChartHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: OType.h3.copyWith(color: c.text)),
        const SizedBox(height: 2),
        Text(subtitle, style: OType.caption.copyWith(color: c.textMuted)),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // On a 320 dp phone the card body is ~240 dp. Stack the trailing
        // control under the title there and whenever text is scaled up.
        final compact =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleBlock,
              if (trailing != null) ...[
                const SizedBox(height: OSpace.xs),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: titleBlock),
            if (trailing != null) ...[
              const SizedBox(width: OSpace.m),
              trailing!,
            ],
          ],
        );
      },
    );
  }
}

class _ChartTotal extends StatelessWidget {
  const _ChartTotal({required this.value, required this.caption});

  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.h3.copyWith(color: c.text),
        ),
        Text(caption, style: OType.caption.copyWith(color: c.textMuted)),
      ],
    );
  }
}

class _ChartAxis extends StatelessWidget {
  const _ChartAxis({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    if (labels.isEmpty) return const SizedBox.shrink();
    final indexes = labels.length <= 3
        ? [for (var i = 0; i < labels.length; i++) i]
        : [0, labels.length ~/ 2, labels.length - 1];
    return Row(
      children: [
        for (var slot = 0; slot < indexes.length; slot++)
          Expanded(
            child: Text(
              labels[indexes[slot]],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: slot == 0
                  ? TextAlign.start
                  : slot == indexes.length - 1
                  ? TextAlign.end
                  : TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
      ],
    );
  }
}

class _ChartRangeTabs extends StatelessWidget {
  const _ChartRangeTabs({
    required this.value,
    required this.onChanged,
    required this.expanded,
  });

  final V2UsageChartRange value;
  final ValueChanged<V2UsageChartRange>? onChanged;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final range in V2UsageChartRange.values)
            if (expanded)
              Expanded(
                child: _ChartRangeTab(
                  range: range,
                  selected: value == range,
                  onChanged: onChanged,
                  expanded: true,
                ),
              )
            else
              _ChartRangeTab(
                range: range,
                selected: value == range,
                onChanged: onChanged,
                expanded: false,
              ),
        ],
      ),
    );
  }
}

class _ChartRangeTab extends StatelessWidget {
  const _ChartRangeTab({
    required this.range,
    required this.selected,
    required this.onChanged,
    required this.expanded,
  });

  final V2UsageChartRange range;
  final bool selected;
  final ValueChanged<V2UsageChartRange>? onChanged;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = range == V2UsageChartRange.sevenDays ? '7 days' : '30 days';
    final semanticLabel = range.label;
    final content = AnimatedContainer(
      duration: OMotion.fast,
      curve: OMotion.standard,
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? OSpace.xs : OSpace.m,
        vertical: OSpace.s,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? c.accentFill : Colors.transparent,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: ExcludeSemantics(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(
            color: selected ? c.onAccent : c.textMuted,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
    if (onChanged == null) {
      // No `OPressable` here: a disabled control must not advertise a tap.
      return Semantics(
        label: semanticLabel,
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
        semanticLabel: semanticLabel,
        child: content,
      ),
    );
  }
}

class _ModelLegendRow extends StatelessWidget {
  const _ModelLegendRow({required this.slice, required this.color});

  final V2ModelShareSlice slice;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      child: Padding(
        padding: const EdgeInsets.only(bottom: OSpace.s),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: OSpace.xs),
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    slice.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (slice.valueLabel.isNotEmpty)
                    Text(
                      slice.valueLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              _percentLabel(slice.percent),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: OType.bodySm.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 168,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Expanded(child: OSkeleton(radius: ORadius.m)),
          const SizedBox(height: OSpace.s),
          Row(
            children: const [
              OSkeleton(width: 64, height: 10),
              Spacer(),
              OSkeleton(width: 40, height: 10),
            ],
          ),
        ],
      ),
    );
  }
}

class _TokenBarsPainter extends CustomPainter {
  const _TokenBarsPainter({
    required this.values,
    required this.maxValue,
    required this.barColor,
    required this.baselineColor,
    required this.progress,
  });

  final List<double> values;
  final double maxValue;
  final Color barColor;
  final Color baselineColor;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 6.0;
    final bottom = size.height - 1;
    final usable = bottom - top;
    if (usable <= 0) return;

    // No grid, no ticks, no axis labels: the bars are the chart and the
    // semantics summary carries the numbers.
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = baselineColor
        ..strokeWidth = 1,
    );

    if (values.isEmpty || maxValue <= 0) return;
    final slot = size.width / values.length;
    final barWidth = math.min(18.0, math.max(2.0, slot * 0.58));
    final paint = Paint()..color = barColor;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value <= 0) continue;
      final height = math.max(
        2.0,
        usable * (value / maxValue).clamp(0.0, 1.0) * progress,
      );
      final left = slot * i + (slot - barWidth) / 2;
      final rect = Rect.fromLTWH(left, bottom - height, barWidth, height);
      final radius = Radius.circular(math.min(4.0, barWidth / 2));
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TokenBarsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.barColor != barColor ||
      oldDelegate.baselineColor != baselineColor ||
      oldDelegate.progress != progress;
}

class _ShareBarPainter extends CustomPainter {
  const _ShareBarPainter({
    required this.percents,
    required this.colors,
    required this.trackColor,
    required this.progress,
  });

  final List<double> percents;
  final List<Color> colors;
  final Color trackColor;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final clip = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(clip, Paint()..color = trackColor);

    final total = percents.fold<double>(0, (sum, value) => sum + value);
    if (total <= 0 || progress <= 0) return;

    canvas.save();
    canvas.clipRRect(clip);
    var x = 0.0;
    for (var i = 0; i < percents.length; i++) {
      final width = percents[i] / total * size.width * progress;
      if (width <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(x, 0, width, size.height),
        Paint()..color = colors[i % colors.length],
      );
      x += width;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShareBarPainter oldDelegate) =>
      oldDelegate.percents != percents ||
      oldDelegate.colors != colors ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.progress != progress;
}

class _ImageLinePainter extends CustomPainter {
  const _ImageLinePainter({
    required this.values,
    required this.maxValue,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.baselineColor,
    required this.progress,
  });

  final List<double> values;
  final double maxValue;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final Color baselineColor;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 6.0;
    final bottom = size.height - 1;
    final usable = bottom - top;
    if (usable <= 0) return;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = top + usable * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    canvas.drawLine(
      Offset(0, bottom),
      Offset(size.width, bottom),
      Paint()
        ..color = baselineColor
        ..strokeWidth = 1,
    );

    if (values.isEmpty || maxValue <= 0) return;

    Offset pointAt(int index) {
      final value = values[index].clamp(0.0, maxValue);
      final x = values.length == 1
          ? size.width / 2
          : size.width * index / (values.length - 1);
      final y = bottom - usable * (value / maxValue) * progress;
      return Offset(x, y);
    }

    final line = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);
    for (var i = 1; i < values.length; i++) {
      final point = pointAt(i);
      line.lineTo(point.dx, point.dy);
    }

    if (values.length > 1) {
      final first = pointAt(0);
      final last = pointAt(values.length - 1);
      final fill = Path.from(line)
        ..lineTo(last.dx, bottom)
        ..lineTo(first.dx, bottom)
        ..close();
      canvas.drawPath(fill, Paint()..color = fillColor);
    }

    canvas.drawPath(
      line,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final dotPaint = Paint()..color = lineColor;
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(pointAt(i), 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_ImageLinePainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.maxValue != maxValue ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.fillColor != fillColor ||
      oldDelegate.gridColor != gridColor ||
      oldDelegate.baselineColor != baselineColor ||
      oldDelegate.progress != progress;
}

/// The empty-state action that is actually wired.
///
/// The old charts always labelled the button "Start a chat" even when no chat
/// callback existed and the tap merely retried the fetch.
Widget? _emptyAction({
  required VoidCallback? onStartChat,
  required VoidCallback? onRetry,
}) {
  if (onStartChat != null) {
    return OButton(
      label: 'Start a chat',
      icon: Icons.chat_bubble_outline_rounded,
      onPressed: onStartChat,
    );
  }
  if (onRetry != null) {
    return OButton(
      label: 'Try again',
      icon: Icons.refresh_rounded,
      onPressed: onRetry,
    );
  }
  return null;
}

Color _sliceColor(OColors c, int index) {
  final base = switch (index % 4) {
    0 => c.accentFill,
    1 => c.success,
    2 => c.warn,
    _ => c.accent,
  };
  return index < 4 ? base : base.withValues(alpha: 0.6);
}

String _percentLabel(double percent) {
  final rounded = percent.roundToDouble();
  return (percent - rounded).abs() < 0.05
      ? '${rounded.toInt()}%'
      : '${percent.toStringAsFixed(1)}%';
}

String _pointValue(V2TokenChartPoint point) {
  if (point.valueLabel.isNotEmpty) {
    // Callers may hand us `8.2M`; the summary should always say the unit.
    return point.valueLabel.toLowerCase().contains('token')
        ? point.valueLabel
        : '${point.valueLabel} tokens';
  }
  return '${_compactNumber(point.value)} tokens';
}

String _compactNumber(double value) {
  if (value >= 1000000000) return '${_trim(value / 1000000000)}B';
  if (value >= 1000000) return '${_trim(value / 1000000)}M';
  if (value >= 1000) return '${_trim(value / 1000)}K';
  return value.round().toString();
}

String _trim(double value) {
  final text = value.toStringAsFixed(value >= 100 ? 0 : 1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}
