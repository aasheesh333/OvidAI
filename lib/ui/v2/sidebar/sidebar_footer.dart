import 'package:flutter/material.dart';

import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

/// Footer navigation for the v2 sidebar: Schedule, Artifacts and Settings.
///
/// Presentational only — all state arrives through [scheduleNextRun] and all
/// actions leave through the callbacks. The three destinations sit side by side
/// at normal text sizes and stack as full-width rows once the text scale goes
/// above [stackedTextScale], so labels are never truncated on a narrow drawer.
///
/// The footer owns its bottom safe-area inset: the surface and top hairline
/// paint behind the inset while the tappable rows stay above it. Nesting this
/// inside another [SafeArea] is safe because the outer one already removes the
/// inset from the [MediaQuery] this widget reads.
class SidebarFooter extends StatelessWidget {
  const SidebarFooter({
    super.key,
    this.onSchedule,
    this.onArtifacts,
    this.onSettings,
    this.scheduleNextRun,
  });

  /// Fired when the Schedule destination is tapped.
  final VoidCallback? onSchedule;

  /// Fired when the Artifacts destination is tapped.
  final VoidCallback? onArtifacts;

  /// Fired when the Settings destination is tapped.
  final VoidCallback? onSettings;

  /// Short "next run" line under the Schedule destination, e.g.
  /// "Next run 9:00 AM". Omitted when null or blank.
  final String? scheduleNextRun;

  /// Text scale above which the three-up layout no longer fits and the
  /// destinations stack vertically.
  static const double stackedTextScale = 1.25;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final nextRun = scheduleNextRun?.trim();
    final subtitle = nextRun == null || nextRun.isEmpty ? null : nextRun;
    final stacked = _isStacked(context);

    final items = <Widget>[
      _FooterItem(
        key: const ValueKey<String>('v2-sidebar-footer-schedule'),
        icon: Icons.calendar_today_rounded,
        label: 'Schedule',
        subtitle: subtitle,
        onTap: onSchedule,
        stacked: stacked,
      ),
      _FooterItem(
        key: const ValueKey<String>('v2-sidebar-footer-artifacts'),
        icon: Icons.inventory_2_outlined,
        label: 'Artifacts',
        onTap: onArtifacts,
        stacked: stacked,
      ),
      _FooterItem(
        key: const ValueKey<String>('v2-sidebar-footer-settings'),
        icon: Icons.settings_outlined,
        label: 'Settings',
        onTap: onSettings,
        stacked: stacked,
      ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(OSpace.s),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const SizedBox(height: OSpace.xs),
                      items[i],
                    ],
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final item in items) Expanded(child: item)],
                ),
        ),
      ),
    );
  }

  bool _isStacked(BuildContext context) {
    // Compare against the 12 sp caption size rather than the raw factor so
    // non-linear text scalers are handled the same way as linear ones.
    final scaler = MediaQuery.textScalerOf(context);
    return scaler.scale(12) / 12 > stackedTextScale;
  }
}

class _FooterItem extends StatelessWidget {
  const _FooterItem({
    super.key,
    required this.icon,
    required this.label,
    this.subtitle,
    this.onTap,
    this.stacked = false,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final subtitle = this.subtitle;

    final labels = Column(
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: stacked ? TextAlign.start : TextAlign.center,
          style: OType.caption.copyWith(color: c.textMuted),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: OSpace.xxs),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: stacked ? TextAlign.start : TextAlign.center,
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ],
    );

    return OPressable(
      onTap: onTap,
      semanticLabel: subtitle == null ? label : '$label, $subtitle',
      // The pressable owns the label; drop the inner text nodes so the
      // destination is announced once, not label-plus-children.
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: OSpace.touch,
            minHeight: OSpace.touch,
          ),
          child: Padding(
            padding: stacked
                ? const EdgeInsets.symmetric(
                    horizontal: OSpace.s,
                    vertical: OSpace.xs,
                  )
                : const EdgeInsets.symmetric(vertical: OSpace.xs),
            child: stacked
                ? Row(
                    children: [
                      Icon(icon, size: 20, color: c.textMuted),
                      const SizedBox(width: OSpace.s),
                      Flexible(child: labels),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 20, color: c.textMuted),
                      const SizedBox(height: OSpace.xs),
                      labels,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
