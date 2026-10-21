import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

const double _tau = 6.283185307179586;
const double _startAngle = -1.5707963267948966;

/// One coloured part of the storage donut and its legend row.
@immutable
class V2StorageSlice {
  const V2StorageSlice({
    required this.label,
    required this.sizeLabel,
    required this.valueGb,
  });

  final String label;
  final String sizeLabel;
  final double valueGb;
}

/// One large file or chat shown in the "Largest items" list.
@immutable
class V2StorageItem {
  const V2StorageItem({
    required this.id,
    required this.name,
    required this.detail,
    required this.sizeLabel,
    this.icon = Icons.insert_drive_file_outlined,
  });

  final String id;
  final String name;
  final String detail;
  final String sizeLabel;
  final IconData icon;
}

/// Injected state for the Storage screen.
///
/// Every number and size string is supplied by the caller: the defaults are
/// deliberately empty so an un-wired screen shows the empty state instead of
/// made-up usage figures.
@immutable
class V2StoragePageData {
  const V2StoragePageData({
    this.usedGb = 0,
    this.totalGb = 0,
    this.slices = const <V2StorageSlice>[],
    this.previewSizeLabel = '0 MB',
    this.cacheSizeLabel = '0 MB',
    this.trashItems = 0,
    this.trashSizeLabel = '0 MB',
    this.largestItems = const <V2StorageItem>[],
    this.offlineLabel,
    this.loading = false,
    this.errorMessage,
    this.onClearPreviews,
    this.onClearCache,
    this.onDeleteOldChats,
    this.onEmptyTrash,
    this.onLargestItemTap,
    this.onGoUpgrade,
    this.onRetry,
  });

  final double usedGb;
  final double totalGb;
  final List<V2StorageSlice> slices;
  final String previewSizeLabel;
  final String cacheSizeLabel;
  final int trashItems;
  final String trashSizeLabel;
  final List<V2StorageItem> largestItems;

  /// Sync note shown under the page. Hidden when null.
  final String? offlineLabel;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onClearPreviews;
  final VoidCallback? onClearCache;
  final VoidCallback? onDeleteOldChats;
  final VoidCallback? onEmptyTrash;
  final ValueChanged<String>? onLargestItemTap;
  final VoidCallback? onGoUpgrade;
  final VoidCallback? onRetry;

  bool get isEmpty => usedGb <= 0 || slices.isEmpty;
}

/// Storage overview with a donut, legend and ways to free up room.
class StoragePage extends StatelessWidget {
  const StoragePage({super.key, required this.data});

  final V2StoragePageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Storage'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (data.isEmpty) {
      return OEmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Storage is empty',
        message:
            'Chats, artifacts, and memory will show up here as you use Ovid.',
        action: OButton(
          label: 'See plans',
          icon: Icons.arrow_forward_rounded,
          onPressed: data.onGoUpgrade,
        ),
      );
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _overview(context),
            _freeUpSpace(context),
            _largestItems(context),
            _upgrade(context),
            if (data.offlineLabel != null && data.offlineLabel!.isNotEmpty)
              _offlineNote(context),
          ],
        ),
      ),
    );
  }

  Widget _overview(BuildContext context) {
    final c = OColors.of(context);
    final ratio = data.totalGb <= 0
        ? 0.0
        : (data.usedGb / data.totalGb).clamp(0, 1).toDouble();
    final percent = (ratio * 100).round();
    final freeGb = (data.totalGb - data.usedGb)
        .clamp(0, data.totalGb)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          children: [
            _DonutChart(
              fraction: ratio,
              slices: [
                for (var i = 0; i < data.slices.length; i++)
                  _DonutPart(
                    value: data.slices[i].valueGb,
                    color: _sliceColor(c, i),
                  ),
              ],
              centerLabel: '$percent%',
              centerCaption: 'used',
            ),
            const SizedBox(height: OSpace.l),
            Text(
              '${_gb(data.usedGb)} GB of ${_gb(data.totalGb)} GB cloud storage used · ${_gb(freeGb)} GB free',
              textAlign: TextAlign.center,
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            Container(
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < data.slices.length; i += 2)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : OSpace.m),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _legend(context, i)),
                          Expanded(
                            child: i + 1 < data.slices.length
                                ? _legend(context, i + 1)
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, int index) {
    final c = OColors.of(context);
    final slice = data.slices[index];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: OSpace.xs),
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _sliceColor(c, index),
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                slice.label,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.xs),
              Text(
                slice.sizeLabel,
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _freeUpSpace(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Free up space',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              'Recommendations',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _actionRow(
                  context,
                  icon: Icons.layers_clear_outlined,
                  title: 'Clear previews',
                  subtitle:
                      '${data.previewSizeLabel} · Temporary renders and screenshots',
                  action: OButton(
                    label: 'Clear',
                    variant: OButtonVariant.secondary,
                    onPressed: data.onClearPreviews,
                  ),
                ),
                Divider(color: c.hairline, height: 1),
                OListRow(
                  icon: Icons.cleaning_services_outlined,
                  title: 'Clear cache',
                  subtitle:
                      '${data.cacheSizeLabel} · Temporary files you can rebuild',
                  showChevron: false,
                  onTap: data.onClearCache,
                  trailing: _stacksActions(context)
                      ? null
                      : OPill(label: data.cacheSizeLabel),
                ),
                Divider(color: c.hairline, height: 1),
                OListRow(
                  icon: Icons.forum_outlined,
                  title: 'Delete old chats',
                  subtitle: 'Archive or remove chats older than 60 days',
                  onTap: data.onDeleteOldChats,
                ),
                Divider(color: c.hairline, height: 1),
                _actionRow(
                  context,
                  icon: Icons.delete_sweep_outlined,
                  title:
                      'Trash · ${data.trashItems} ${data.trashItems == 1 ? 'item' : 'items'}',
                  subtitle:
                      '${data.trashSizeLabel} · Deleted in the last 30 days',
                  danger: true,
                  action: OButton(
                    label: 'Empty',
                    variant: OButtonVariant.danger,
                    onPressed: data.onEmptyTrash,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A row whose action button sits beside the text normally and under it when
  /// the user's text size is large. Keeping the button in the trailing slot at
  /// 200 % squeezes the title to a few pixels wide.
  Widget _actionRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required OButton action,
    bool danger = false,
  }) {
    OListRow row({Widget? trailing}) => OListRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      danger: danger,
      showChevron: false,
      trailing: trailing,
    );
    if (!_stacksActions(context)) return row(trailing: action);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(),
        Padding(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.m),
          child: SizedBox(width: double.infinity, child: action),
        ),
      ],
    );
  }

  Widget _largestItems(BuildContext context) {
    final c = OColors.of(context);
    final count = data.largestItems.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Largest items',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '$count ${count == 1 ? 'item' : 'items'}',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (data.largestItems.isEmpty)
            OCard(
              child: Text(
                'Nothing large yet. Big chats and files will show up here.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < data.largestItems.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    OListRow(
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(ORadius.m),
                        ),
                        child: Icon(
                          data.largestItems[i].icon,
                          size: 19,
                          color: c.textMuted,
                        ),
                      ),
                      title: data.largestItems[i].name,
                      // At large text sizes the size label moves into the
                      // subtitle so the row cannot overflow or squeeze the
                      // name into a one-character column.
                      subtitle: _stacksActions(context)
                          ? '${data.largestItems[i].detail} · ${data.largestItems[i].sizeLabel}'
                          : data.largestItems[i].detail,
                      showChevron: false,
                      onTap: data.onLargestItemTap == null
                          ? null
                          : () =>
                                data.onLargestItemTap!(data.largestItems[i].id),
                      trailing: _stacksActions(context)
                          ? null
                          : Text(
                              data.largestItems[i].sizeLabel,
                              style: OType.bodyStrong.copyWith(color: c.text),
                            ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _upgrade(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        accent: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.cloud_upload_outlined,
                    size: 24,
                    color: c.onAccent,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: OSpace.s,
                        runSpacing: OSpace.xs,
                        children: [
                          Text(
                            'Need more room?',
                            style: OType.h2.copyWith(color: c.text),
                          ),
                          const OPill(label: 'Upgrade', tone: OPillTone.accent),
                        ],
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        'Upgrade for 5 GB with Ovid Go or expand to 50 GB with Ovid Plus.',
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'See plans',
              icon: Icons.arrow_forward_rounded,
              onPressed: data.onGoUpgrade,
            ),
          ],
        ),
      ),
    );
  }

  Widget _offlineNote(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_rounded, size: 18, color: c.textFaint),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              data.offlineLabel!,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

String _gb(double value) => value.toStringAsFixed(1);

/// True when the text scale is large enough that a row's action must move to
/// its own line. 1.5× is the point where a trailing 48 dp button leaves less
/// than half the row for the label at 320 dp.
bool _stacksActions(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) >= 14 * 1.5;

/// Token-derived slice colours: violet, blue, green, amber.
Color _sliceColor(OColors c, int index) {
  return switch (index) {
    0 => c.accentFill,
    1 => Color.lerp(c.accentFill, c.success, 0.55) ?? c.success,
    2 => c.success,
    3 => c.warn,
    _ => c.textFaint,
  };
}

class _DonutPart {
  const _DonutPart({required this.value, required this.color});

  final double value;
  final Color color;
}

class _DonutChart extends StatelessWidget {
  const _DonutChart({
    required this.fraction,
    required this.slices,
    required this.centerLabel,
    required this.centerCaption,
  });

  final double fraction;
  final List<_DonutPart> slices;
  final String centerLabel;
  final String centerCaption;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SizedBox(
      width: 200,
      height: 200,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: fraction.clamp(0, 1)),
            duration: OMove.duration(context, OMotion.slow),
            curve: OMotion.emphasized,
            builder: (context, value, _) => CustomPaint(
              size: const Size.square(200),
              painter: _DonutPainter(
                fraction: value,
                parts: slices,
                trackColor: c.surfaceRaised,
                strokeWidth: 18,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(centerLabel, style: OType.display.copyWith(color: c.text)),
              Text(
                centerCaption,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.fraction,
    required this.parts,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double fraction;
  final List<_DonutPart> parts;
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

    final total = parts.fold<double>(0, (sum, part) => sum + part.value);
    if (total <= 0) return;

    var start = _startAngle;
    for (final part in parts) {
      final sweep = part.value / total * _tau * fraction;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = part.color;
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.parts != parts ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
