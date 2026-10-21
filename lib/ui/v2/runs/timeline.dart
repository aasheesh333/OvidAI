import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this component's English copy during the ARB pass.

/// Visual state of one [V2TimelineItem] node.
///
/// The colour is never the only signal: every state also has a plain-English
/// [label] that is shown in the status pill and read by screen readers.
enum V2TimelineStatus {
  neutral,
  running,
  success,
  warning,
  danger;

  /// Plain-English word for the status pill and the accessibility label.
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
/// [title] is required. [description] stays visible under the title, while
/// [expandedDetail] is revealed when the row is tapped. Supplying
/// [expandedDetail] makes the row expandable; [initiallyExpanded] starts it
/// open. [footer] can hold detail widgets such as source chips or a file card
/// and is rendered under the description and the expanded detail.
///
/// The caller owns the content: the component never formats times, durations
/// or statuses beyond the plain-English [V2TimelineStatus.label].
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
  /// [V2Timeline.onItemTap] and [V2Timeline.onExpandedChanged].
  final String id;

  /// The step or event name.
  final String title;

  /// One or two lines that are always visible under [title].
  final String? description;

  /// Clock label for when the step happened, e.g. "10:41".
  final String? timeLabel;

  /// How long the step took, e.g. "4m 12s".
  final String? durationLabel;

  final V2TimelineStatus status;

  /// Overrides the default [V2TimelineStatus.label] in the pill and the
  /// accessibility label.
  final String? statusLabel;

  /// Node glyph. When null a glyph is chosen from [status].
  final IconData? icon;

  /// Extra plain-English detail revealed by tapping the row.
  final String? expandedDetail;

  /// Optional content rendered under the text, such as chips or a file card.
  final Widget? footer;

  /// Whether an expandable row starts open.
  final bool initiallyExpanded;

  /// True when tapping the row can reveal [expandedDetail].
  bool get isExpandable => expandedDetail != null;

  /// The status word shown and announced; empty for a bare neutral node.
  String get effectiveStatusLabel => statusLabel ?? status.label;

  /// The full label a screen reader announces for the row header.
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

/// Called when an expandable row opens or closes.
typedef V2TimelineExpansionChanged = void Function(String id, bool expanded);

/// A reusable vertical timeline.
///
/// Renders a node per item joined by a hairline connector, with the item's
/// time, status pill, duration, description and optional expandable detail.
/// The last item's connector is omitted. Rows with [V2TimelineItem.expandedDetail]
/// toggle their detail on tap; every row also reports taps through
/// [onItemTap].
///
/// The component is presentational and theme-aware: it reads every colour from
/// [OColors], uses the shared type and spacing tokens, keeps a 48 dp minimum
/// tap target, and lays out at 320 dp with 200 % text. Entrance motion goes
/// through [OStagger], which becomes a plain column under reduced motion.
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

  /// Fires for every row tap with the item id. For expandable rows this fires
  /// alongside the expansion toggle, so a caller can navigate or log without
  /// owning the open state.
  final ValueChanged<String>? onItemTap;

  /// Fires after an expandable row opens or closes.
  final V2TimelineExpansionChanged? onExpandedChanged;

  /// Optional label for the whole list, e.g. "Execution trajectory".
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final list = OStagger(
      children: [
        for (var i = 0; i < items.length; i++)
          _V2TimelineTile(
            key: ValueKey(items[i].id),
            item: items[i],
            isLast: i == items.length - 1,
            onItemTap: onItemTap,
            onExpandedChanged: onExpandedChanged,
          ),
      ],
    );

    if (semanticLabel == null) return list;
    return Semantics(container: true, label: semanticLabel, child: list);
  }
}

class _V2TimelineTile extends StatefulWidget {
  const _V2TimelineTile({
    super.key,
    required this.item,
    required this.isLast,
    this.onItemTap,
    this.onExpandedChanged,
  });

  final V2TimelineItem item;
  final bool isLast;
  final ValueChanged<String>? onItemTap;
  final V2TimelineExpansionChanged? onExpandedChanged;

  @override
  State<_V2TimelineTile> createState() => _V2TimelineTileState();
}

class _V2TimelineTileState extends State<_V2TimelineTile> {
  late bool _expanded =
      widget.item.initiallyExpanded && widget.item.isExpandable;

  bool get _tappable => widget.item.isExpandable || widget.onItemTap != null;

  @override
  void didUpdateWidget(covariant _V2TimelineTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A row that stops being expandable must not keep a stale open state.
    if (!widget.item.isExpandable && _expanded) _expanded = false;
  }

  void _handleTap() {
    final item = widget.item;
    if (item.isExpandable) {
      setState(() => _expanded = !_expanded);
      widget.onExpandedChanged?.call(item.id, _expanded);
    }
    widget.onItemTap?.call(item.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final item = widget.item;
    final statusColor = _statusColor(c, item.status);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                ExcludeSemantics(
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: c.bg,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.hairline),
                    ),
                    child: Icon(
                      item.icon ?? _iconFor(item.status),
                      key: ValueKey('v2-timeline-node-${item.id}'),
                      size: 14,
                      color: statusColor,
                    ),
                  ),
                ),
                if (!widget.isLast)
                  Expanded(
                    child: Container(
                      key: ValueKey('v2-timeline-connector-${item.id}'),
                      width: 2,
                      color: c.hairline,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.isLast ? 0 : OSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _semanticTextBlock(c),
                  if (item.footer != null) ...[
                    const SizedBox(height: OSpace.s),
                    item.footer!,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The header, description and expanded detail form one screen-reader node
  /// per row, so a description is never read before the row it belongs to.
  /// Footer widgets stay outside, because they can own their own actions.
  Widget _semanticTextBlock(OColors c) {
    final item = widget.item;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(c),
        if (item.description != null) ...[
          const SizedBox(height: OSpace.xs),
          Text(
            item.description!,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
        if (item.isExpandable && _expanded) ...[
          const SizedBox(height: OSpace.s),
          OFadeSlide(
            duration: OMotion.fast,
            offset: const Offset(0, 0.02),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
                border: Border.all(color: c.hairline),
              ),
              child: Text(
                item.expandedDetail!,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ),
          ),
        ],
      ],
    );

    final body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      child: Align(alignment: Alignment.topLeft, child: text),
    );
    final label = _screenReaderLabel();

    if (!_tappable) {
      return Semantics(
        container: true,
        label: label,
        child: ExcludeSemantics(child: body),
      );
    }

    return Semantics(
      container: true,
      expanded: item.isExpandable ? _expanded : null,
      child: OPressable(
        onTap: _handleTap,
        semanticLabel: label,
        child: ExcludeSemantics(child: body),
      ),
    );
  }

  /// Time, status, duration, description and any revealed detail as one
  /// sentence list. Punctuation is normalised so the caller can end strings
  /// with a period without producing "..".
  String _screenReaderLabel() {
    final item = widget.item;
    final parts = <String>[
      item.semanticLabel,
      if (item.description != null) item.description!,
      if (item.isExpandable && _expanded) item.expandedDetail!,
      if (item.isExpandable) _expanded ? 'Hide details' : 'Show details',
    ];
    return parts
        .map(_withoutFullStop)
        .where((part) => part.isNotEmpty)
        .join('. ');
  }

  String _withoutFullStop(String value) {
    final text = value.trim();
    if (text.endsWith('.') || text.endsWith('!') || text.endsWith('?')) {
      return text.substring(0, text.length - 1).trimRight();
    }
    return text;
  }

  /// Time, status and duration form a wrapping meta line; the title and
  /// chevron get their own row. Nothing can be squeezed off a 320 dp screen at
  /// 200 % text, and the two rows keep the reading order predictable.
  Widget _header(OColors c) {
    final item = widget.item;
    final meta = <Widget>[
      if (item.timeLabel != null && item.timeLabel!.isNotEmpty)
        _TimelineMeta(
          icon: Icons.schedule_rounded,
          label: item.timeLabel!,
          color: c.textMuted,
          mono: true,
        ),
      if (item.durationLabel != null && item.durationLabel!.isNotEmpty)
        _TimelineMeta(
          icon: Icons.timer_outlined,
          label: item.durationLabel!,
          color: c.textFaint,
        ),
      if (item.effectiveStatusLabel.isNotEmpty)
        OPill(
          label: item.effectiveStatusLabel,
          tone: _pillTone(item.status),
          dot: item.status == V2TimelineStatus.running,
        ),
    ];

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (meta.isNotEmpty) ...[
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: meta,
          ),
          const SizedBox(height: OSpace.xs),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                item.title,
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (item.isExpandable) ...[
              const SizedBox(width: OSpace.xs),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: c.textFaint,
                ),
              ),
            ],
          ],
        ),
      ],
    );

    return content;
  }

  Color _statusColor(OColors c, V2TimelineStatus status) => switch (status) {
    V2TimelineStatus.neutral => c.textMuted,
    V2TimelineStatus.running => c.accent,
    V2TimelineStatus.success => c.success,
    V2TimelineStatus.warning => c.warn,
    V2TimelineStatus.danger => c.danger,
  };

  OPillTone _pillTone(V2TimelineStatus status) => switch (status) {
    V2TimelineStatus.neutral => OPillTone.neutral,
    V2TimelineStatus.running => OPillTone.accent,
    V2TimelineStatus.success => OPillTone.success,
    V2TimelineStatus.warning => OPillTone.warn,
    V2TimelineStatus.danger => OPillTone.danger,
  };

  IconData _iconFor(V2TimelineStatus status) => switch (status) {
    V2TimelineStatus.neutral => Icons.circle_outlined,
    V2TimelineStatus.running => Icons.autorenew_rounded,
    V2TimelineStatus.success => Icons.check_rounded,
    V2TimelineStatus.warning => Icons.warning_amber_rounded,
    V2TimelineStatus.danger => Icons.close_rounded,
  };
}

/// A small icon + label pair used for time and duration.
class _TimelineMeta extends StatelessWidget {
  const _TimelineMeta({
    required this.icon,
    required this.label,
    required this.color,
    this.mono = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (mono ? OType.mono : OType.caption).copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
