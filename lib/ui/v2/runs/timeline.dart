import 'package:flutter/material.dart';

import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this component's English copy during the ARB pass.

/// Visual state of one [V2TimelineItem] node.
///
/// The colour is never the only signal: every state also has a plain-English
/// [label] that is read by screen readers.
enum V2TimelineStatus {
  neutral,
  running,
  success,
  warning,
  danger;

  /// Plain-English word for the accessibility label.
  ///
  /// [neutral] has no default word because a neutral node is not making a
  /// claim about the step; callers can still pass an explicit
  /// [V2TimelineItem.statusLabel] such as "Cancelled".
  String get label => switch (this) {
    V2TimelineStatus.neutral => '',
    V2TimelineStatus.running => 'Running',
    V2TimelineStatus.success => 'Completed',
    V2TimelineStatus.warning => 'Needs attention',
    V2TimelineStatus.danger => 'Failed',
  };
}

/// One row on a [V2Timeline].
///
/// [title] is required. The row is one line: the title and, when supplied,
/// [durationLabel]. Extra fields are retained so existing callers keep
/// compiling; the minimal timeline does not render prose, footers or an
/// expandable detail panel.
@immutable
class V2TimelineItem {
  const V2TimelineItem({
    required this.id,
    required this.title,
    this.description,
    this.timeLabel,
    this.durationLabel,
    this.status = V2TimelineStatus.neutral,
    this.statusLabel,
    this.icon,
    this.expandedDetail,
    this.footer,
    this.initiallyExpanded = false,
  });

  /// Stable identity. Used for keys and passed back through
  /// [V2Timeline.onItemTap].
  final String id;

  /// The step or event name.
  final String title;

  /// Retained for callers. Not rendered: the row is one line.
  final String? description;

  /// Clock label for when the step happened, e.g. "10:41".
  final String? timeLabel;

  /// How long the step took, e.g. "4m 12s".
  final String? durationLabel;

  final V2TimelineStatus status;

  /// Overrides the default [V2TimelineStatus.label] in the accessibility
  /// label.
  final String? statusLabel;

  /// Node glyph. When null a glyph is chosen from [status].
  final IconData? icon;

  /// Retained for callers. Not rendered.
  final String? expandedDetail;

  /// Retained for callers. Not rendered.
  final Widget? footer;

  /// Retained for callers. The minimal row has no expansion.
  final bool initiallyExpanded;

  /// True when tapping the row can reveal [expandedDetail].
  bool get isExpandable => expandedDetail != null;

  /// The status word shown and announced; empty for a bare neutral node.
  String get effectiveStatusLabel => statusLabel ?? status.label;

  /// The full label a screen reader announces for the row.
  ///
  /// Order is time, title, status, duration so the list reads chronologically.
  String get semanticLabel {
    final parts = <String>[
      if (timeLabel != null && timeLabel!.isNotEmpty) timeLabel!,
      title,
      if (effectiveStatusLabel.isNotEmpty) effectiveStatusLabel,
      if (durationLabel != null && durationLabel!.isNotEmpty) durationLabel!,
    ];
    return parts.join(', ');
  }
}

/// Called when a row is tapped.
typedef V2TimelineExpansionChanged = void Function(String id, bool expanded);

/// A reusable one-line vertical timeline.
///
/// Renders one row per item: a status glyph, the title and the duration.
/// The component is presentational and theme-aware: it reads every colour from
/// [OColors], uses the shared type and spacing tokens, keeps a 48 dp minimum
/// tap target, and lays out at 320 dp with 200 % text.
class V2Timeline extends StatelessWidget {
  const V2Timeline({
    super.key,
    required this.items,
    this.onItemTap,
    this.onExpandedChanged,
    this.semanticLabel,
  });

  /// Rendered in the order supplied.
  final List<V2TimelineItem> items;

  /// Fires for every row tap with the item id.
  final ValueChanged<String>? onItemTap;

  /// Retained for callers. The minimal row has no expansion.
  final V2TimelineExpansionChanged? onExpandedChanged;

  /// Optional label for the whole list, e.g. "Execution trajectory".
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final list = Column(
      children: [
        for (final item in items)
          _V2TimelineRow(
            key: ValueKey(item.id),
            item: item,
            onTap: onItemTap == null ? null : () => onItemTap!(item.id),
          ),
      ],
    );

    if (semanticLabel == null) return list;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: list,
    );
  }
}

class _V2TimelineRow extends StatelessWidget {
  const _V2TimelineRow({
    super.key,
    required this.item,
    this.onTap,
  });

  final V2TimelineItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final statusColor = _statusColor(c, item.status);
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                item.icon ?? _iconFor(item.status),
                key: ValueKey('v2-timeline-node-${item.id}'),
                size: 18,
                color: statusColor,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            if (item.durationLabel != null &&
                item.durationLabel!.isNotEmpty) ...[
              const SizedBox(width: OSpace.s),
              ExcludeSemantics(
                child: Text(
                  item.durationLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) {
      return Semantics(
        container: true,
        label: item.semanticLabel,
        child: content,
      );
    }
    return OPressable(
      onTap: onTap,
      semanticLabel: item.semanticLabel,
      child: content,
    );
  }

  Color _statusColor(OColors c, V2TimelineStatus status) => switch (status) {
    V2TimelineStatus.neutral => c.textMuted,
    V2TimelineStatus.running => c.accent,
    V2TimelineStatus.success => c.success,
    V2TimelineStatus.warning => c.warn,
    V2TimelineStatus.danger => c.danger,
  };

  IconData _iconFor(V2TimelineStatus status) => switch (status) {
    V2TimelineStatus.neutral => Icons.circle_outlined,
    V2TimelineStatus.running => Icons.autorenew_rounded,
    V2TimelineStatus.success => Icons.check_rounded,
    V2TimelineStatus.warning => Icons.warning_amber_rounded,
    V2TimelineStatus.danger => Icons.close_rounded,
  };
}
