import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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
    this.endsAt,
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

  /// Plain-English next run, e.g. "Tomorrow, 9:00 AM". Used only when neither
  /// [cadence] nor [nextRunAt] is available.
  final String? nextRun;

  /// The server's next occurrence, used when the cadence cannot be expanded.
  final DateTime? nextRunAt;

  /// The real cadence, so the next run is computed from it rather than trusted
  /// from a stale label.
  final V2CadenceDraft? cadence;

  /// The last day this schedule may run, when it has an end date.
  final DateTime? endsAt;
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

  V2ScheduleItem copyWith({
    bool? enabled,
    bool? lastRunFailed,
    String? failureMessage,
  }) {
    return V2ScheduleItem(
      id: id,
      title: title,
      description: description,
      rule: rule,
      nextRun: nextRun,
      nextRunAt: nextRunAt,
      cadence: cadence,
      endsAt: endsAt,
      enabled: enabled ?? this.enabled,
      lastRunFailed: lastRunFailed ?? this.lastRunFailed,
      failureMessage: failureMessage ?? this.failureMessage,
      sessionTitle: sessionTitle,
      createdLabel: createdLabel,
      completedRuns: completedRuns,
      totalRuns: totalRuns,
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
          if (onMore != null || onRetry != null || onCreate != null)
            OIconButton(
              icon: Icons.more_vert_rounded,
              semanticLabel: 'More options',
              onPressed: onMore ?? () => _openMore(context),
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
    final items = <Widget>[
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
    ];

    void addGroup(String label, List<V2ScheduleItem> schedules) {
      if (schedules.isEmpty) return;
      items
        ..add(const SizedBox(height: OSpace.l))
        ..add(OSectionHeader(label: label, padding: EdgeInsets.zero))
        ..add(const SizedBox(height: OSpace.m));
      for (var i = 0; i < schedules.length; i++) {
        final card = _card(context, c, schedules[i]);
        if (i >= 8) {
          items.add(card);
          continue;
        }
        // Only the first screenful animates; a long rule list must not start
        // an entrance timer for every off-screen card.
        final delay = OMotion.stagger * i;
        items.add(
          OFadeSlide(
            delay: delay > const Duration(milliseconds: 400)
                ? const Duration(milliseconds: 400)
                : delay,
            child: card,
          ),
        );
      }
    }

    addGroup('Active schedules (${active.length})', active);
    addGroup('Paused (${paused.length})', paused);

    items
      ..add(const SizedBox(height: OSpace.l))
      ..add(
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
      )
      ..add(const SizedBox(height: OSpace.s));

    // Lazy: the card widgets are cheap to construct, but only the visible
    // ones are mounted and laid out.
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
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

    if (schedule.ruleLabel.isNotEmpty) {
      addMeta(Icons.schedule_rounded, schedule.ruleLabel, color: c.accent);
    }
    final nextRun = schedule.nextRunLabel(data.now ?? DateTime.now());
    if (nextRun != null) {
      addMeta(
        Icons.update_rounded,
        'Next: $nextRun',
        color: c.success,
        strong: true,
      );
    }
    if (schedule.endsAt != null) {
      addMeta(
        Icons.event_busy_rounded,
        'Ends ${MaterialLocalizations.of(context).formatMediumDate(schedule.endsAt!)}',
        color: c.textFaint,
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
                    if (menuEnabled)
                      OIconButton(
                        icon: Icons.more_vert_rounded,
                        semanticLabel: 'More options for ${schedule.title}',
                        size: 18,
                        onPressed: () => _openMenu(context, schedule),
                      ),                  ],
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
          'Future runs stop immediately. Past runs stay in the run history. '
          'This cannot be undone.',
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

  /// The app-bar menu, so the screen always has a real action even when the
  /// host does not inject one.
  Future<void> _openMore(BuildContext context) async {
    final action = await showOSheet<String>(
      context,
      title: 'Schedules',
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onCreate != null)
              OListRow(
                icon: Icons.add_alarm_rounded,
                title: 'New schedule',
                showChevron: false,
                onTap: () => Navigator.of(sheetContext).pop('new'),
              ),
            if (onRetry != null)
              OListRow(
                icon: Icons.refresh_rounded,
                title: 'Refresh',
                showChevron: false,
                onTap: () => Navigator.of(sheetContext).pop('refresh'),
              ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'new':
        onCreate?.call();
      case 'refresh':
        onRetry?.call();
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
