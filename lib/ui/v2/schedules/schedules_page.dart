import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
    this.enabled = true,
    this.lastRunFailed = false,
    this.failureMessage,
    this.sessionTitle,
    this.createdLabel,
    this.completedRuns,
    this.totalRuns,
  });

  final String id;
  final String title;
  final String description;

  /// Plain-English rule, e.g. "Every weekday at 9:00 AM".
  final String rule;

  /// Plain-English next run, e.g. "Tomorrow, 9:00 AM".
  final String? nextRun;
  final bool enabled;
  final bool lastRunFailed;
  final String? failureMessage;

  /// The chat this schedule was created from, shown for context.
  final String? sessionTitle;

  /// Plain-English creation date, e.g. "May 12, 2026".
  final String? createdLabel;

  /// How many runs have finished, and how many were planned in total.
  final int? completedRuns;
  final int? totalRuns;

  /// "12 of 30 runs" when both counts are known, otherwise a single count.
  String? get runCountLabel {
    if (totalRuns != null) {
      return '${completedRuns ?? 0} of $totalRuns runs';
    }
    if (completedRuns != null) {
      return '$completedRuns ${completedRuns == 1 ? 'run' : 'runs'} completed';
    }
    return null;
  }
}

@immutable
class V2SchedulesData {
  const V2SchedulesData({
    this.status = V2SchedulesStatus.content,
    this.schedules = const <V2ScheduleItem>[],
    this.errorMessage =
        'We could not load your schedules. Check your connection and try again.',
  });

  final V2SchedulesStatus status;
  final List<V2ScheduleItem> schedules;
  final String errorMessage;
}

/// All of the user's recurring tasks, with a plain-English rule per card.
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
    this.onMore,
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
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Schedules',
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: onMore,
          ),
        ],
      ),
      body: OFadeSlide(
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _explainer(c),
        const SizedBox(height: OSpace.xl),
        OEmptyState(
          icon: Icons.calendar_month_rounded,
          title: 'No schedules yet',
          message:
              'Ovid can work while you sleep. Set a task to run on its own, and the result will be waiting for you.',
          action: OButton(
            label: 'Create a schedule',
            icon: Icons.add_rounded,
            onPressed: onCreate,
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, OColors c) {
    final active = [
      for (final schedule in data.schedules)
        if (schedule.enabled) schedule,
    ];
    final paused = [
      for (final schedule in data.schedules)
        if (!schedule.enabled) schedule,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _explainer(c),
        const SizedBox(height: OSpace.m),
        Align(
          alignment: Alignment.centerLeft,
          child: OPill(
            label: data.schedules.length == 1
                ? '1 total rule'
                : '${data.schedules.length} total rules',
          ),
        ),
        if (active.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _group(context, c, 'Active schedules (${active.length})', active),
        ],
        if (paused.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _group(context, c, 'Paused (${paused.length})', paused),
        ],
        const SizedBox(height: OSpace.l),
        OCard(
          padding: const EdgeInsets.all(OSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.add_alarm_rounded, size: 20, color: c.accent),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      'Need another one? Ovid can run a second task on its '
                      'own schedule.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.s),
              Align(
                alignment: Alignment.centerRight,
                child: OButton(
                  label: 'New schedule',
                  variant: OButtonVariant.ghost,
                  size: OButtonSize.compact,
                  onPressed: onCreate,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.s),
      ],
    );
  }

  Widget _group(
    BuildContext context,
    OColors c,
    String label,
    List<V2ScheduleItem> schedules,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OSectionHeader(label: label, padding: EdgeInsets.zero),
        const SizedBox(height: OSpace.m),
        OStagger(
          children: [
            for (final schedule in schedules) _card(context, c, schedule),
          ],
        ),
      ],
    );
  }

  Widget _explainer(OColors c) {
    return OCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              Icons.notifications_active_rounded,
              size: 20,
              color: c.accent,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ovid can work while you sleep',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Runs a task on a schedule, browses or writes code, and tells you when it is done.',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, OColors c, V2ScheduleItem schedule) {
    final onTap = onScheduleTap;
    final onToggleSchedule = onToggle;
    final onRetry = onRetryRun;
    final runCount = schedule.runCountLabel;
    final menuEnabled =
        onScheduleMenu != null ||
        onEdit != null ||
        onToggle != null ||
        onRunNow != null ||
        onDelete != null;
    final meta = <Widget>[];
    void addMeta(
      IconData icon,
      String text, {
      Color? color,
      bool strong = false,
    }) {
      if (meta.isNotEmpty) meta.add(const SizedBox(height: OSpace.s));
      meta.add(_metaRow(c, icon, text, color: color, strong: strong));
    }

    if (schedule.rule.isNotEmpty) {
      addMeta(Icons.schedule_rounded, schedule.rule, color: c.accent);
    }
    if (schedule.enabled && schedule.nextRun != null) {
      addMeta(
        Icons.update_rounded,
        'Next: ${schedule.nextRun}',
        color: c.success,
        strong: true,
      );
    }
    if (runCount != null) {
      addMeta(Icons.history_rounded, runCount);
    }
    if (schedule.sessionTitle != null && schedule.sessionTitle!.isNotEmpty) {
      addMeta(
        Icons.chat_bubble_outline_rounded,
        'From ${schedule.sessionTitle}',
      );
    }
    if (schedule.createdLabel != null && schedule.createdLabel!.isNotEmpty) {
      addMeta(
        Icons.calendar_today_rounded,
        'Created ${schedule.createdLabel}',
        color: c.textFaint,
      );
    }

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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _status(c, schedule),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        schedule.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      if (schedule.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          schedule.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    OIconButton(
                      icon: Icons.more_vert_rounded,
                      semanticLabel: 'More options for ${schedule.title}',
                      size: 18,
                      onPressed: menuEnabled
                          ? () => _openMenu(context, schedule)
                          : null,
                    ),
                  ],
                ),
              ],
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: OSpace.m),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(color: c.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: meta,
                ),
              ),
            ],
            if (schedule.lastRunFailed) ...[
              const SizedBox(height: OSpace.m),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(color: c.danger.withValues(alpha: 0.30)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 18,
                          color: c.danger,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            schedule.failureMessage ??
                                'Last run failed. Your rule is still saved.',
                            style: OType.caption.copyWith(color: c.danger),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OSpace.s),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: OButton(
                        label: 'Retry',
                        variant: OButtonVariant.danger,
                        onPressed: onRetry == null
                            ? null
                            : () => onRetry(schedule),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metaRow(
    OColors c,
    IconData icon,
    String text, {
    Color? color,
    bool strong = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: color ?? c.textMuted),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            text,
            style: (strong ? OType.caption : OType.bodySm).copyWith(
              color: color ?? c.text,
              fontWeight: strong ? FontWeight.w600 : null,
            ),
          ),
        ),
      ],
    );
  }

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
              OListRow(
                icon: Icons.edit_outlined,
                title: 'Edit',
                showChevron: false,
                enabled: onEdit != null,
                onTap: onEdit == null
                    ? null
                    : () => Navigator.of(sheetContext).pop('edit'),
              ),
              OListRow(
                icon: schedule.enabled
                    ? Icons.pause_circle_outline_rounded
                    : Icons.play_circle_outline_rounded,
                title: schedule.enabled ? 'Pause' : 'Resume',
                subtitle: schedule.enabled
                    ? 'Stop future runs until you turn it back on.'
                    : 'Start running on its schedule again.',
                showChevron: false,
                enabled: onToggle != null,
                onTap: onToggle == null
                    ? null
                    : () => Navigator.of(sheetContext).pop('toggle'),
              ),
              OListRow(
                icon: Icons.play_arrow_rounded,
                title: 'Run now',
                subtitle: 'Start one run without waiting for the next time.',
                showChevron: false,
                enabled: onRunNow != null,
                onTap: onRunNow == null
                    ? null
                    : () => Navigator.of(sheetContext).pop('run'),
              ),
              OListRow(
                icon: Icons.delete_outline_rounded,
                title: 'Delete',
                subtitle: 'Remove this schedule and stop future runs.',
                danger: true,
                showChevron: false,
                enabled: onDelete != null,
                onTap: onDelete == null
                    ? null
                    : () => Navigator.of(sheetContext).pop('delete'),
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
      case 'toggle':
        onToggle?.call(schedule, !schedule.enabled);
      case 'run':
        onRunNow?.call(schedule);
      case 'delete':
        onDelete?.call(schedule);
    }
  }

  Widget _status(OColors c, V2ScheduleItem schedule) {
    if (schedule.lastRunFailed) {
      return _statusLine(c, c.danger, 'Action needed');
    }
    if (!schedule.enabled) {
      return const OPill(label: 'Paused');
    }
    return _statusLine(c, c.success, 'Running active');
  }

  Widget _statusLine(OColors c, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            label,
            style: OType.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
