import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'cadence_picker.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2SchedulesStatus { loading, content, empty, error }

@immutable
class V2ScheduleItem {
  const V2ScheduleItem({
    required this.id,
    required this.title,
    required this.description,
    required this.rule,
    this.nextRun,
    this.nextRunAt,
    this.cadence,
    this.enabled = true,
    this.lastRunFailed = false,
  });

  final String id;
  final String title;
  final String description;

  /// Plain-English rule, e.g. "Every weekday at 9:00 AM".
  final String rule;

  /// Plain-English next run, e.g. "Tomorrow, 9:00 AM". Used only when neither
  /// [cadence] nor [nextRunAt] is available.
  final String? nextRun;

  /// The server's next occurrence, used when the cadence cannot be expanded.
  final DateTime? nextRunAt;

  /// The real cadence, so the next run is computed from it rather than trusted
  /// from a stale label.
  final V2CadenceDraft? cadence;
  final bool enabled;
  final bool lastRunFailed;

  /// The rule to show: the cadence is the source of truth when present.
  String get ruleLabel {
    final cadence = this.cadence;
    if (cadence != null && cadence.isValid) return describeCadence(cadence);
    return rule;
  }

  /// The next run computed from the real cadence, never a hardcoded label.
  ///
  /// A paused schedule has no next run, and a server timestamp that has already
  /// passed is not shown as if it were still ahead.
  String? nextRunLabel(DateTime now) {
    if (!enabled) return null;
    final cadence = this.cadence;
    if (cadence != null) {
      final computed = describeNextRun(cadence, now);
      if (computed != null) return computed;
    }
    final at = nextRunAt?.toLocal();
    if (at != null) {
      if (!at.isAfter(now)) return null;
      return describeNextRunAt(at, now);
    }
    return nextRun;
  }

  V2ScheduleItem copyWith({bool? enabled, bool? lastRunFailed}) {
    return V2ScheduleItem(
      id: id,
      title: title,
      description: description,
      rule: rule,
      nextRun: nextRun,
      nextRunAt: nextRunAt,
      cadence: cadence,
      enabled: enabled ?? this.enabled,
      lastRunFailed: lastRunFailed ?? this.lastRunFailed,
    );
  }
}

@immutable
class V2SchedulesData {
  const V2SchedulesData({
    this.status = V2SchedulesStatus.content,
    this.schedules = const <V2ScheduleItem>[],
    this.now,
    this.errorMessage =
        'We could not load your schedules. Check your connection and try again.',
  });

  final V2SchedulesStatus status;
  final List<V2ScheduleItem> schedules;

  /// Clock used for the computed next-run labels. Injected for deterministic
  /// tests; defaults to now.
  final DateTime? now;
  final String errorMessage;
}

/// All of the user's recurring tasks. One card per schedule: the prompt, its
/// cadence and the next run.
class SchedulesPage extends StatelessWidget {
  const SchedulesPage({
    super.key,
    required this.data,
    this.onScheduleTap,
    this.onScheduleMenu,
    this.onToggle,
    this.onRetryRun,
    this.onEdit,
    this.onRunNow,
    this.onDelete,
    this.onCreate,
    this.onRetry,
  });

  final V2SchedulesData data;
  final ValueChanged<V2ScheduleItem>? onScheduleTap;

  /// Escape hatch: replaces the built-in Edit / Pause / Run now / Delete menu.
  final ValueChanged<V2ScheduleItem>? onScheduleMenu;
  final void Function(V2ScheduleItem schedule, bool enabled)? onToggle;
  final ValueChanged<V2ScheduleItem>? onRetryRun;
  final ValueChanged<V2ScheduleItem>? onEdit;
  final ValueChanged<V2ScheduleItem>? onRunNow;
  final ValueChanged<V2ScheduleItem>? onDelete;
  final VoidCallback? onCreate;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScreen(
      title: 'Schedules',
      showBack: true,
      actions: [
        if (onCreate != null)
          OIconButton(
            icon: Icons.add_rounded,
            semanticLabel: 'New schedule',
            onPressed: onCreate,
          ),
      ],
      child: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (data.status) {
            V2SchedulesStatus.loading => const OSkeletonList(rows: 5),
            V2SchedulesStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: onRetry,
            ),
            V2SchedulesStatus.empty => _empty(c),
            V2SchedulesStatus.content =>
              data.schedules.isEmpty ? _empty(c) : _content(context, c),
          },
        ),
      ),
    );
  }

  Widget _empty(OColors c) {
    return OEmptyState(
      icon: Icons.calendar_month_rounded,
      title: 'No schedules yet',
      message: 'Set a task to run on its own.',
      action: onCreate == null
          ? null
          : OButton(
              label: 'New schedule',
              icon: Icons.add_rounded,
              onPressed: onCreate,
            ),
    );
  }

  Widget _content(BuildContext context, OColors c) {
    final schedules = [
      for (final schedule in data.schedules)
        if (schedule.enabled) schedule,
      for (final schedule in data.schedules)
        if (!schedule.enabled) schedule,
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      itemCount: schedules.length,
      itemBuilder: (context, index) {
        final card = _card(context, c, schedules[index]);
        if (index >= 8) return card;
        final delay = OMotion.stagger * index;
        return OFadeSlide(
          delay: delay > const Duration(milliseconds: 400)
              ? const Duration(milliseconds: 400)
              : delay,
          child: card,
        );
      },
    );
  }

  Widget _card(BuildContext context, OColors c, V2ScheduleItem schedule) {
    final onTap = onScheduleTap;
    final onToggleSchedule = onToggle;
    final menuEnabled =
        onScheduleMenu != null ||
        onEdit != null ||
        onRunNow != null ||
        onDelete != null;
    final prompt = schedule.description.trim().isEmpty
        ? schedule.title
        : schedule.description.trim();
    final nextRun = schedule.nextRunLabel(data.now ?? DateTime.now());
    // One line carries the cadence and, when the schedule is on, its next run.
    final meta = [
      if (schedule.ruleLabel.isNotEmpty) schedule.ruleLabel,
      ?nextRun,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: OCard(
        onTap: onTap == null ? null : () => onTap(schedule),
        semanticLabel: '${schedule.title}. ${schedule.rule}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    prompt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                MergeSemantics(
                  child: Semantics(
                    label: 'Turn ${schedule.title} on or off',
                    toggled: schedule.enabled,
                    enabled: onToggleSchedule != null,
                    child: Switch(
                      value: schedule.enabled,
                      onChanged: onToggleSchedule == null
                          ? null
                          : (value) => onToggleSchedule(schedule, value),
                      thumbColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.disabled)
                            ? c.textFaint
                            : (schedule.enabled ? c.onAccent : c.textFaint),
                      ),
                      trackColor: WidgetStateProperty.resolveWith(
                        (states) =>
                            states.contains(WidgetState.disabled) ||
                                !schedule.enabled
                            ? c.surfaceRaised
                            : c.accentFill,
                      ),
                      trackOutlineColor: WidgetStatePropertyAll(
                        c.hairlineStrong,
                      ),
                    ),
                  ),
                ),
                if (menuEnabled)
                  OIconButton(
                    icon: Icons.more_vert_rounded,
                    semanticLabel: 'More options for ${schedule.title}',
                    size: 18,
                    onPressed: () => _openMenu(context, schedule),
                  ),
              ],
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: OSpace.s),
              _metaRow(c, Icons.schedule_rounded, meta),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaRow(OColors c, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: c.textMuted),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ),
      ],
    );
  }

  /// The card menu holds edit, run-now and delete — the switch on the card
  /// already owns pausing, and a row without a handler is never offered.
  Future<void> _openMenu(BuildContext context, V2ScheduleItem schedule) async {
    final override = onScheduleMenu;
    if (override != null) {
      override(schedule);
      return;
    }
    final action = await showOSheet<String>(
      context,
      title: schedule.title,
      builder: (sheetContext) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.s, 0, OSpace.s, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onEdit != null)
                OListRow(
                  icon: Icons.edit_outlined,
                  title: 'Edit',
                  showChevron: false,
                  onTap: () => Navigator.of(sheetContext).pop('edit'),
                ),
              if (onRunNow != null)
                OListRow(
                  icon: Icons.play_arrow_rounded,
                  title: 'Run now',
                  showChevron: false,
                  onTap: () => Navigator.of(sheetContext).pop('run'),
                ),
              if (onDelete != null)
                OListRow(
                  icon: Icons.delete_outline_rounded,
                  title: 'Delete',
                  danger: true,
                  showChevron: false,
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
                ),
            ],
          ),
        );
      },
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'edit':
        onEdit?.call(schedule);
      case 'run':
        onRunNow?.call(schedule);
      case 'delete':
        await _confirmDelete(context, schedule);
    }
  }

  /// Deleting is irreversible for future runs, so it is always confirmed. The
  /// row disappears only after the wiring layer's delete succeeds.
  Future<void> _confirmDelete(
    BuildContext context,
    V2ScheduleItem schedule,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete “${schedule.title}”?'),
        content: const Text(
          'Future runs stop immediately. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    onDelete?.call(schedule);
  }
}
