import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// The storage buckets the product names, in the order the breakdown shows
/// them. Uploads and cache are part of the five-way breakdown; previews stays
/// for the existing Storage screen's render cache.
///
/// Each bucket carries its product label; the legend uses the same copy.
enum V2StorageCategory {
  chats('Chats'),
  artifacts('Artifacts'),
  uploads('Uploads'),
  memory('Memory'),
  cache('Cache'),
  previews('Previews'),

  /// Fills the gap when the caller's buckets do not add up to the used total.
  /// Without it the legend would sum to less than the number above it.
  other('Other');

  const V2StorageCategory(this.label);

  final String label;
}

/// One category's share of the storage donut.
@immutable
class V2StorageCategoryBytes {
  const V2StorageCategoryBytes({
    required this.category,
    required this.bytes,
    this.sizeLabel = '',
  });

  final V2StorageCategory category;

  /// Bytes used by this category. Negative values are treated as zero.
  final int bytes;

  /// Optional pre-formatted size. When empty the bytes are formatted here.
  final String sizeLabel;

  int get safeBytes => bytes < 0 ? 0 : bytes;
}

enum V2StorageBreakdownStatus { loading, content, empty, error }

/// Injected state for the storage breakdown section.
///
/// Every number defaults to zero and the entry list is empty, so an un-wired
/// section shows the empty state instead of invented usage figures.
@immutable
class V2StorageBreakdownData {
  const V2StorageBreakdownData({
    this.title = 'Storage',
    this.usedBytes = 0,
    this.totalBytes = 0,
    this.amountLabel = '',
    this.totalLabel = '',
    this.entries = const <V2StorageCategoryBytes>[],
    this.status = V2StorageBreakdownStatus.content,
    this.errorMessage =
        'Storage could not be loaded. Check your connection and try again.',
    this.emptyTitle = 'Nothing stored yet',
    this.emptyMessage =
        'Chats, artifacts, uploads, memory, and cache appear here as you use '
        'Ovid.',
    this.emptyActionLabel = 'Start a chat',
    this.selectedCategory,
    this.onEmptyAction,
    this.onRetry,
    this.onCategoryTap,
  });

  /// Section header above the card.
  final String title;

  /// Total bytes in use. When zero, the sum of [entries] is used instead.
  final int usedBytes;

  /// The plan capacity. Zero means "capacity unknown", which draws a full
  /// ring instead of a partial one.
  final int totalBytes;

  /// Optional pre-formatted total, for example "3 GB".
  final String amountLabel;

  /// Optional pre-formatted capacity, for example "5 GB".
  final String totalLabel;

  /// Category shares. Empty or all-zero entries render the empty state.
  final List<V2StorageCategoryBytes> entries;

  final V2StorageBreakdownStatus status;

  final String errorMessage;
  final String emptyTitle;
  final String emptyMessage;
  final String emptyActionLabel;

  /// Highlighted legend row. The chart dims the other slices and the centre
  /// shows this category's size and share.
  final V2StorageCategory? selectedCategory;

  /// Next action from the empty state. When null the button is not shown.
  final VoidCallback? onEmptyAction;
  final VoidCallback? onRetry;

  /// Tapping a legend row selects it. When null the legend is read-only.
  final ValueChanged<V2StorageCategory>? onCategoryTap;
}

/// Formats a byte count as a short, human storage size.
///
/// Sizes under 10 units keep one decimal ("1.5 KB"); larger sizes drop it
/// ("819 MB", "3 GB"). Negative input renders "0 B" because a storage figure
/// is never allowed to look like an error.
String formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value < 10 && unit > 0
      ? _trimTrailingZero(value.toStringAsFixed(1))
      : value.toStringAsFixed(0);
  return '$text ${units[unit]}';
}

String _trimTrailingZero(String value) =>
    value.endsWith('.0') ? value.substring(0, value.length - 2) : value;

String _entrySizeLabel(V2StorageCategoryBytes entry) =>
    entry.sizeLabel.isNotEmpty
    ? entry.sizeLabel
    : formatStorageBytes(entry.safeBytes);

/// Result of making a category list agree with the used total.
@immutable
class V2StorageReconciliation {
  const V2StorageReconciliation({
    required this.entries,
    required this.usedBytes,
  });

  final List<V2StorageCategoryBytes> entries;
  final int usedBytes;

  int get totalBytes =>
      entries.fold<int>(0, (sum, entry) => sum + entry.safeBytes);

  bool get addsUp => totalBytes == usedBytes;
}

/// Makes the breakdown add up to the total shown above it.
///
/// A category list is only allowed to under-report: when the caller's buckets
/// are smaller than [usedBytes] the remainder becomes an explicit "Other"
/// bucket. When the buckets are larger, the larger sum becomes the used total
/// so the legend and the heading still describe the same bytes. Either way
/// [V2StorageReconciliation.addsUp] is true for the returned pair.
V2StorageReconciliation reconcileStorageBreakdown(
  List<V2StorageCategoryBytes> entries,
  int usedBytes,
) {
  final sum = entries.fold<int>(0, (total, entry) => total + entry.safeBytes);
  if (usedBytes <= sum) {
    return V2StorageReconciliation(entries: entries, usedBytes: sum);
  }
  return V2StorageReconciliation(
    entries: [
      ...entries,
      V2StorageCategoryBytes(
        category: V2StorageCategory.other,
        bytes: usedBytes - sum,
      ),
    ],
    usedBytes: usedBytes,
  );
}

/// Splits bytes into whole percentages that always add up to 100.
///
/// Uses the largest-remainder method so a breakdown never shows 33 / 33 / 33
/// and silently loses a point. Ties go to the earlier category, which keeps
/// the legend stable between rebuilds.
List<int> storagePercentageSplit(List<int> bytes) {
  if (bytes.isEmpty) return const <int>[];
  final safe = [for (final value in bytes) value < 0 ? 0 : value];
  final total = safe.fold<int>(0, (sum, value) => sum + value);
  if (total <= 0) return List<int>.filled(safe.length, 0);

  final exact = [for (final value in safe) value / total * 100];
  final result = [for (final value in exact) value.floor()];
  var remaining = 100 - result.fold<int>(0, (sum, value) => sum + value);

  final order = List<int>.generate(exact.length, (index) => index)
    ..sort((a, b) {
      final byRemainder = (exact[b] - exact[b].floor()).compareTo(
        exact[a] - exact[a].floor(),
      );
      return byRemainder != 0 ? byRemainder : a.compareTo(b);
    });

  for (final index in order) {
    if (remaining <= 0) break;
    result[index]++;
    remaining--;
  }
  return result;
}

/// Donut breakdown of storage by category, with a text legend.
///
/// The widget is presentational: it renders [data] and exposes only the
/// retry / empty-state callbacks it is given. It owns no timers or streams.
class StorageBreakdown extends StatelessWidget {
  const StorageBreakdown({super.key, required this.data});

  final V2StorageBreakdownData data;

  @override
  Widget build(BuildContext context) {
    return OFadeSlide(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          OSectionHeader(
            label: data.title,
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          switch (data.status) {
            V2StorageBreakdownStatus.loading => const _BreakdownSkeleton(),
            V2StorageBreakdownStatus.error => OErrorState(
              title: 'Storage unavailable',
              message: data.errorMessage,
              onRetry: data.onRetry,
            ),
            V2StorageBreakdownStatus.empty => _empty(),
            V2StorageBreakdownStatus.content =>
              _hasUsage ? _content(context) : _empty(),
          },
        ],
      ),
    );
  }

  bool get _hasUsage {
    if (data.usedBytes > 0) return true;
    return data.entries.any((entry) => entry.safeBytes > 0);
  }

  int get _entryBytes =>
      data.entries.fold<int>(0, (sum, entry) => sum + entry.safeBytes);

  /// The category list and used total as one consistent pair. This is what
  /// keeps the donut, the centre number and the legend adding up.
  V2StorageReconciliation get _reconciled => reconcileStorageBreakdown(
    data.entries,
    data.usedBytes > 0 ? data.usedBytes : _entryBytes,
  );

  List<V2StorageCategoryBytes> get _entries => _reconciled.entries;

  int get _usedBytes => _reconciled.usedBytes;

  Widget _empty() {
    return OEmptyState(
      compact: true,
      icon: Icons.donut_large_rounded,
      title: data.emptyTitle,
      message: data.emptyMessage,
      action: data.onEmptyAction == null || data.emptyActionLabel.isEmpty
          ? null
          : OButton(
              label: data.emptyActionLabel,
              icon: Icons.chat_bubble_outline_rounded,
              onPressed: data.onEmptyAction,
            ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final entries = _entries;
    final used = _usedBytes;
    final amount = data.amountLabel.isNotEmpty
        ? data.amountLabel
        : formatStorageBytes(used);
    final total = data.totalLabel.isNotEmpty
        ? data.totalLabel
        : (data.totalBytes > 0 ? formatStorageBytes(data.totalBytes) : '');
    final percentages = storagePercentageSplit([
      for (final entry in entries) entry.safeBytes,
    ]);
    final selectedIndex = data.selectedCategory == null
        ? -1
        : entries.indexWhere(
            (entry) => entry.category == data.selectedCategory,
          );
    final selected = selectedIndex < 0 ? null : entries[selectedIndex];
    final selectedPercent = selected == null
        ? null
        : percentages[selectedIndex];

    final centerLabel = selected == null ? amount : _entrySizeLabel(selected);
    final centerCaption = selected == null
        ? (total.isEmpty ? 'used' : 'of $total')
        : '$selectedPercent% of used';

    return OCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.l,
                OSpace.l,
                OSpace.m,
              ),
              child: Center(
                child: _Donut(
                  fraction: data.totalBytes <= 0
                      ? 1
                      : (used / data.totalBytes).clamp(0, 1).toDouble(),
                  slices: [
                    for (final entry in entries)
                      _DonutSlice(
                        value: entry.safeBytes.toDouble(),
                        color: _categoryColor(c, entry.category).withValues(
                          alpha:
                              selected == null ||
                                  entry.category == selected.category
                              ? 1
                              : 0.22,
                        ),
                      ),
                  ],
                  centerLabel: centerLabel,
                  centerCaption: centerCaption,
                  semanticLabel: _chartSemantics(
                    entries: entries,
                    amount: amount,
                    total: total,
                    percentages: percentages,
                    selected: selected,
                    selectedPercent: selectedPercent,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: c.hairline),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.all(OSpace.l),
                child: Text(
                  'No category detail yet.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              )
            else
              for (var i = 0; i < entries.length; i++) ...[
                if (i > 0) Divider(height: 1, color: c.hairline),
                _LegendRow(
                  entry: entries[i],
                  percentage: percentages[i],
                  fraction: used <= 0 ? 0 : entries[i].safeBytes / used,
                  color: _categoryColor(c, entries[i].category),
                  selected: entries[i].category == data.selectedCategory,
                  onTap: data.onCategoryTap == null
                      ? null
                      : () => data.onCategoryTap!(entries[i].category),
                ),
              ],
          ],
        ),
      ),
    );
  }

  String _chartSemantics({
    required List<V2StorageCategoryBytes> entries,
    required String amount,
    required String total,
    required List<int> percentages,
    required V2StorageCategoryBytes? selected,
    required int? selectedPercent,
  }) {
    final buffer = StringBuffer('Storage: $amount');
    buffer.write(total.isEmpty ? ' used' : ' used of $total');
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      buffer.write(
        '. ${entry.category.label} ${_entrySizeLabel(entry)}, '
        '${percentages[i]}%',
      );
    }
    if (selected != null) {
      buffer.write(
        '. Selected ${selected.category.label}: '
        '${_entrySizeLabel(selected)}, $selectedPercent% of used',
      );
    }
    return buffer.toString();
  }
}

/// Stable token-derived colour for each category. Violet, teal, amber, green,
/// magenta and grey keep every slice distinct in light and dark.
Color _categoryColor(OColors c, V2StorageCategory category) {
  return switch (category) {
    V2StorageCategory.chats => c.accentFill,
    V2StorageCategory.artifacts =>
      Color.lerp(c.accentFill, c.success, 0.55) ?? c.success,
    V2StorageCategory.uploads => c.warn,
    V2StorageCategory.memory => c.success,
    V2StorageCategory.cache => c.textFaint,
    V2StorageCategory.previews => Color.lerp(c.warn, c.danger, 0.45) ?? c.warn,
    V2StorageCategory.other => c.hairlineStrong,
  };
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.entry,
    required this.percentage,
    required this.fraction,
    required this.color,
    required this.selected,
    this.onTap,
  });

  final V2StorageCategoryBytes entry;
  final int percentage;
  final double fraction;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final size = _entrySizeLabel(entry);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // At 200 % the size and percentage cannot share the line with the label
    // inside a 320 dp phone, so they move under it instead of being clipped.
    final stacked = textScale > 1.3;

    final label = Text(
      entry.category.label,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: OType.bodySm.copyWith(
        color: c.text,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final sizeText = Text(
      size,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.caption.copyWith(color: c.textMuted),
    );
    final percentText = Text(
      '$percentage%',
      maxLines: 1,
      textAlign: stacked ? TextAlign.start : TextAlign.end,
      style: OType.label.copyWith(color: c.text),
    );

    final row = AnimatedContainer(
      duration: OMotion.fast,
      curve: OMotion.standard,
      color: selected ? c.accentSoft : Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.l,
            vertical: OSpace.s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: stacked
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              label,
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: OSpace.s,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [sizeText, percentText],
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: label),
                              const SizedBox(width: OSpace.s),
                              sizeText,
                              const SizedBox(width: OSpace.m),
                              percentText,
                            ],
                          ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.s),
              Padding(
                padding: const EdgeInsets.only(left: 22),
                child: _CategoryBar(
                  key: ValueKey('storage-breakdown-bar-${entry.category.name}'),
                  value: fraction,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      container: true,
      button: onTap != null,
      selected: selected,
      label:
          '${entry.category.label}, $size, $percentage%'
          '${selected ? ', selected' : ''}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: OPressable(onTap: onTap, child: row),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({super.key, required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value.clamp(0, 1).toDouble()),
      duration: OMove.duration(context, OMotion.slow),
      curve: OMotion.emphasized,
      builder: (context, animated, _) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: animated,
          minHeight: 5,
          backgroundColor: c.surfaceRaised,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ),
    );
  }
}

class _BreakdownSkeleton extends StatelessWidget {
  const _BreakdownSkeleton();

  @override
  Widget build(BuildContext context) {
    return OCard(
      key: const ValueKey('storage-breakdown-loading'),
      padding: const EdgeInsets.all(OSpace.l),
      child: Column(
        children: [
          const Center(child: OSkeleton(width: 176, height: 176, radius: 88)),
          const SizedBox(height: OSpace.l),
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(height: OSpace.m),
            const Row(
              children: [
                OSkeleton(width: 10, height: 10, radius: 5),
                SizedBox(width: OSpace.m),
                Expanded(child: OSkeleton(height: 14)),
                SizedBox(width: OSpace.m),
                OSkeleton(width: 56, height: 14),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DonutSlice {
  const _DonutSlice({required this.value, required this.color});

  final double value;
  final Color color;
}

class _Donut extends StatelessWidget {
  const _Donut({
    required this.fraction,
    required this.slices,
    required this.centerLabel,
    required this.centerCaption,
    required this.semanticLabel,
  });

  final double fraction;
  final List<_DonutSlice> slices;
  final String centerLabel;
  final String centerCaption;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      key: const ValueKey('storage-breakdown-chart'),
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: 0,
                  end: fraction.clamp(0, 1).toDouble(),
                ),
                duration: OMove.duration(context, OMotion.slow),
                curve: OMotion.emphasized,
                builder: (context, value, _) => CustomPaint(
                  size: const Size.square(200),
                  painter: _DonutPainter(
                    fraction: value,
                    slices: slices,
                    trackColor: c.surfaceRaised,
                    strokeWidth: 18,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: OSpace.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      centerLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: OType.h2.copyWith(color: c.text),
                    ),
                    Text(
                      centerCaption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.fraction,
    required this.slices,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double fraction;
  final List<_DonutSlice> slices;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, track);

    final total = slices.fold<double>(0, (sum, slice) => sum + slice.value);
    if (total <= 0) return;

    var start = -math.pi / 2;
    for (final slice in slices) {
      final sweep = slice.value / total * math.pi * 2 * fraction;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = slice.color;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.slices != slices ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
