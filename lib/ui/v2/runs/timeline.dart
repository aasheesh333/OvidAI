import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

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

/// One labelled block inside an expanded [V2TimelineItem].
///
/// The timeline never formats the value: it belongs to the run. [label] is
/// optional so a plain excerpt can be shown without inventing a section name.
@immutable
class V2TimelineDetail {
  const V2TimelineDetail({
    required this.value,
    this.label,
    this.mono = false,
    this.onTap,
  });

  final String? label;
  final String value;

  /// Renders the value in the monospace face (tool names, paths, commands).
  final bool mono;

  /// When set, the value is a real control (e.g. a source that opens in the
  /// browser) instead of static text.
  final VoidCallback? onTap;
}

/// One row on a [V2Timeline].
///
/// [title] is required. [description] stays visible under the title. A row is
/// expandable only when it carries real detail in [details] or
/// [expandedDetail]; a row without detail is a plain, non-interactive line.
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
    this.details = const <V2TimelineDetail>[],
    this.initiallyExpanded = false,
    this.errorMessage,
    this.tapHint,
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

  /// Overrides the default [V2TimelineStatus.label].
  final String? statusLabel;

  /// Node glyph. When null a glyph is chosen from [status].
  final IconData? icon;

  /// Extra plain-English detail revealed by tapping the row.
  ///
  /// Kept alongside [details] for callers that only have one paragraph.
  final String? expandedDetail;

  /// Labelled blocks revealed by tapping the row.
  final List<V2TimelineDetail> details;

  /// Whether an expandable row starts open.
  final bool initiallyExpanded;

  /// The failure reason, shown once under the row and never repeated in the
  /// expanded detail.
  final String? errorMessage;

  /// What tapping a non-expandable row does, e.g. "Open subagent".
  final String? tapHint;

  /// True when tapping the row can reveal detail.
  bool get isExpandable =>
      (expandedDetail?.trim().isNotEmpty ?? false) ||
      details.any((detail) => detail.value.trim().isNotEmpty);

  /// The rows rendered inside the expansion panel, in order.
  List<V2TimelineDetail> get expansionDetails => <V2TimelineDetail>[
    if (expandedDetail?.trim().isNotEmpty ?? false)
      V2TimelineDetail(value: expandedDetail!.trim()),
    for (final detail in details)
      if (detail.value.trim().isNotEmpty) detail,
  ];

  /// The status word announced by a screen reader; empty for a bare neutral
  /// node.
  String get effectiveStatusLabel {
    final override = statusLabel?.trim();
    if (override != null && override.isNotEmpty) return override;
    return status.label;
  }

  /// Time, title, status and duration, in reading order.
  String get semanticLabel => <String>[
    if (timeLabel != null && timeLabel!.trim().isNotEmpty) timeLabel!.trim(),
    title,
    if (effectiveStatusLabel.isNotEmpty) effectiveStatusLabel,
    if (durationLabel != null && durationLabel!.trim().isNotEmpty)
      durationLabel!.trim(),
  ].join(', ');
}

/// Called when an expandable row opens or closes.
typedef V2TimelineExpansionChanged = void Function(String id, bool expanded);

/// A reusable vertical timeline.
///
/// Renders a node per item joined by a hairline connector, with the item's
/// time, status, duration, description and optional expandable detail. The
/// last item's connector is omitted. Rows with real detail toggle that detail
/// on tap; non-expandable rows are tappable only when [onItemTap] is supplied.
///
/// The component is presentational and theme-aware: it reads every colour from
/// [OColors], uses the shared type and spacing tokens, keeps a 48 dp minimum
/// tap target, and lays out at 320 dp with 200 % text. It returns a [Column],
/// not a scrollable, so a host can place it inside its own list; hosts with
/// long histories should build [V2TimelineRow]s from a lazy list instead.
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

  /// Fires after an expandable row opens or closes.
  final V2TimelineExpansionChanged? onExpandedChanged;

  /// Optional label for the whole list, e.g. "Execution trajectory".
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++)
          V2TimelineRow(
            key: ValueKey<String>(items[i].id),
            item: items[i],
            index: i,
            total: items.length,
            isLast: i == items.length - 1,
            onTap: onItemTap == null ? null : () => onItemTap!(items[i].id),
            onExpandedChanged: onExpandedChanged == null
                ? null
                : (expanded) => onExpandedChanged!(items[i].id, expanded),
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

/// One row of a [V2Timeline].
///
/// Public so a long history can render these from a `ListView.builder` while
/// keeping the same node, status, expansion and semantics as [V2Timeline].
///
/// Expansion is uncontrolled by default. Pass [expanded] to keep it in the
/// host's state (a lazy list recycles rows, and a host that wants an open row
/// to survive scrolling must own the flag); [onExpandedChanged] reports the
/// requested value either way.
class V2TimelineRow extends StatefulWidget {
  const V2TimelineRow({
    super.key,
    required this.item,
    required this.index,
    required this.total,
    this.isLast = false,
    this.expanded,
    this.onExpandedChanged,
    this.onTap,
    this.positionLabel,
  });

  final V2TimelineItem item;

  /// Zero-based position in the timeline, used for the announced order.
  final int index;
  final int total;
  final bool isLast;

  /// Overrides the "Step N of M" announcement, e.g. "Subagent 1 of 2".
  final String? positionLabel;

  /// Controlled expansion state. Null lets the row own it.
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// Runs when the row is tapped. Expandable rows toggle their detail and
  /// still report the tap; non-expandable rows report the tap alone.
  final VoidCallback? onTap;

  @override
  State<V2TimelineRow> createState() => _V2TimelineRowState();
}

class _V2TimelineRowState extends State<V2TimelineRow> {
  late bool _expanded = widget.item.initiallyExpanded;

  bool get _isExpanded =>
      widget.item.isExpandable && (widget.expanded ?? _expanded);

  bool get _canTap => widget.item.isExpandable || widget.onTap != null;

  @override
  void didUpdateWidget(covariant V2TimelineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _expanded = widget.item.initiallyExpanded;
      return;
    }
    // A row that stops being expandable must not keep a stale open state.
    if (!widget.item.isExpandable) _expanded = false;
  }

  void _handleTap() {
    final item = widget.item;
    if (item.isExpandable) {
      final next = !_isExpanded;
      if (widget.expanded == null) setState(() => _expanded = next);
      widget.onExpandedChanged?.call(next);
    }
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final item = widget.item;
    final statusColor = _statusColor(c, item.status);
    final expanded = _isExpanded;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                _node(context, c, item, statusColor),
                if (!widget.isLast)
                  Expanded(
                    child: Container(
                      key: ValueKey<String>('v2-timeline-connector-${item.id}'),
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
                  _semantics(
                    label: _screenReaderLabel(),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: OSpace.touch,
                      ),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _header(context, c, item, statusColor),
                      ),
                    ),
                  ),
                  if (expanded) _detailPanel(context, c, item),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _node(
    BuildContext context,
    OColors c,
    V2TimelineItem item,
    Color statusColor,
  ) {
    final node = Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: c.bg,
        shape: BoxShape.circle,
        border: Border.all(color: c.hairline),
      ),
      child: Icon(
        item.icon ?? _iconFor(item.status),
        key: ValueKey<String>('v2-timeline-node-${item.id}'),
        size: 14,
        color: statusColor,
      ),
    );
    // Only a running row animates. Once it finishes the pulse widget leaves
    // the tree, so no ticker survives the run.
    if (item.status != V2TimelineStatus.running) {
      return ExcludeSemantics(child: node);
    }
    return ExcludeSemantics(child: OPulse(child: node));
  }

  /// The visible header is one screen-reader node. Its label is the whole
  /// announcement, so the title, status and duration are never read twice.
  Widget _semantics({required String label, required Widget child}) {
    final item = widget.item;
    final expanded = _isExpanded;
    final hint = item.isExpandable
        ? (expanded ? 'Hide details' : 'Show details')
        : item.tapHint;
    if (!_canTap) {
      return Semantics(
        container: true,
        label: label,
        sortKey: OrdinalSortKey(widget.index.toDouble()),
        child: ExcludeSemantics(child: child),
      );
    }
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      expanded: item.isExpandable ? expanded : null,
      label: label,
      hint: hint,
      sortKey: OrdinalSortKey(widget.index.toDouble()),
      onTap: _handleTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _handleTap,
          child: child,
        ),
      ),
    );
  }

  Widget _header(
    BuildContext context,
    OColors c,
    V2TimelineItem item,
    Color statusColor,
  ) {
    final meta = <Widget>[
      if (item.timeLabel != null && item.timeLabel!.trim().isNotEmpty)
        _meta(c, item.timeLabel!.trim(), c.textFaint),
      if (_statusText(item).isNotEmpty)
        _meta(c, _statusText(item), statusColor, strong: true),
      if (item.durationLabel != null && item.durationLabel!.trim().isNotEmpty)
        _meta(c, item.durationLabel!.trim(), c.textFaint),
    ];
    final description = item.description?.trim() ?? '';
    final error = item.errorMessage?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (item.isExpandable) ...[
                const SizedBox(width: OSpace.xs),
                Padding(
                  padding: const EdgeInsets.only(top: OSpace.xxs),
                  child: AnimatedRotation(
                    turns: _isExpanded ? 0.25 : 0,
                    duration: OMove.duration(context, OMotion.fast),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: c.textFaint,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (description.isNotEmpty) ...[
            const SizedBox(height: OSpace.xxs),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
          if (meta.isNotEmpty) ...[
            const SizedBox(height: OSpace.xs),
            Wrap(
              spacing: OSpace.s,
              runSpacing: OSpace.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: meta,
            ),
          ],
          if (error.isNotEmpty) ...[
            const SizedBox(height: OSpace.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, size: 14, color: c.danger),
                const SizedBox(width: OSpace.xs),
                Expanded(
                  child: Text(
                    error,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.danger),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _meta(OColors c, String value, Color color, {bool strong = false}) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.caption.copyWith(
        color: color,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }

  Widget _detailPanel(BuildContext context, OColors c, V2TimelineItem item) {
    final details = item.expansionDetails;
    return AnimatedSize(
      duration: OMove.duration(context, OMotion.fast),
      curve: OMotion.standard,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: OSpace.s),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < details.length; i++) ...[
                if (i > 0) const SizedBox(height: OSpace.m),
                if (details[i].label != null &&
                    details[i].label!.trim().isNotEmpty) ...[
                  Text(
                    details[i].label!.trim(),
                    style: OType.caption.copyWith(
                      color: c.textFaint,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: OSpace.xxs),
                ],
                _detailValue(context, c, details[i]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailValue(
    BuildContext context,
    OColors c,
    V2TimelineDetail detail,
  ) {
    final text = Text(
      detail.value,
      style: (detail.mono ? OType.mono : OType.bodySm).copyWith(
        color: detail.onTap == null ? c.textMuted : c.text,
        decoration: detail.onTap == null ? null : TextDecoration.underline,
        decorationColor: c.hairlineStrong,
      ),
    );
    if (detail.onTap == null) return text;
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: detail.value,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: detail.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: text),
                const SizedBox(width: OSpace.s),
                Icon(Icons.open_in_new_rounded, size: 14, color: c.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Completed steps carry their outcome in the glyph; only a state that
  /// needs a word (running, failed, explicit host label) prints one.
  String _statusText(V2TimelineItem item) {
    if (item.status == V2TimelineStatus.success &&
        (item.statusLabel?.trim().isEmpty ?? true)) {
      return '';
    }
    return item.effectiveStatusLabel;
  }

  String _screenReaderLabel() {
    final item = widget.item;
    final error = item.errorMessage?.trim() ?? '';
    final position =
        widget.positionLabel?.trim() ??
        'Step ${widget.index + 1} of ${widget.total}';
    return <String>[
      if (position.isNotEmpty) position,
      item.semanticLabel,
      if (error.isNotEmpty) error,
    ].join(', ');
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
