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

  /// The next occurrence as a real instant, from the cadence or the server's
  /// timestamp. Null when the schedule is paused, when neither source can be
  /// expanded, or when the only timestamp has already passed.
  ///
  /// This is what orders the list and what the summary's "next in 4h" is
  /// measured from — never a label that cannot be compared.
  DateTime? nextOccurrence(DateTime now) {
    if (!enabled) return null;
    final computed = cadence?.nextRunAfter(now);
    if (computed != null) return computed;
    final at = nextRunAt?.toLocal();
    if (at != null && at.isAfter(now)) return at;
    return null;
  }

  /// The next run computed from the real cadence, never a hardcoded label.
  ///
  /// A paused schedule has no next run, and a server timestamp that has already
  /// passed is not shown as if it were still ahead.
  String? nextRunLabel(DateTime now) {
    if (!enabled) return null;
    final next = nextOccurrence(now);
    if (next != null) return describeNextRunAt(next, now);
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

  /// The list in display order: the schedule that runs next first, then by
  /// title, with paused schedules last.
  ///
  /// The next occurrence is computed once per row, so a large list does not
  /// re-expand every cadence on every comparison.
  List<V2ScheduleItem> ordered(DateTime now) {
    final keyed = <(V2ScheduleItem, DateTime?)>[
      for (final schedule in schedules)
        (schedule, schedule.nextOccurrence(now)),
    ];
    keyed.sort((a, b) {
      final aNext = a.$2;
      final bNext = b.$2;
      if (aNext != null && bNext != null) {
        final byTime = aNext.compareTo(bNext);
        if (byTime != 0) return byTime;
      } else if (aNext != null) {
        return -1;
      } else if (bNext != null) {
        return 1;
      }
      // Paused rows have no next occurrence, so they fall below every row that
      // can still run, whatever their title.
      if (a.$1.enabled != b.$1.enabled) return a.$1.enabled ? -1 : 1;
      return a.$1.title.toLowerCase().compareTo(b.$1.title.toLowerCase());
    });
    return <V2ScheduleItem>[for (final entry in keyed) entry.$1];
  }

  /// One line over the list: "3 schedules · next in 4h".
  ///
  /// The count is every saved schedule; the "next" is the earliest occurrence
  /// among the enabled ones, so a paused row never claims the queue. When
  /// nothing is enabled the line says so instead of inventing a time.
  String summary(DateTime now) {
    final total = schedules.length;
    final count = '$total ${total == 1 ? 'schedule' : 'schedules'}';
    DateTime? next;
    for (final schedule in schedules) {
      final at = schedule.nextOccurrence(now);
      if (at == null) continue;
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next != null) {
      return '$count · next in ${_timeUntil(next.difference(now))}';
    }
    final anyEnabled = schedules.any((schedule) => schedule.enabled);
    return '$count · ${anyEnabled ? 'next run unknown' : 'all paused'}';
  }
}

/// A compact distance for the summary line: "12m", "4h", "2d".
String _timeUntil(Duration until) {
  final minutes = until.inMinutes;
  if (minutes < 1) return 'under a minute';
  if (minutes < Duration.minutesPerHour) return '${minutes}m';
  if (minutes < Duration.minutesPerDay) {
    final hours = (minutes / Duration.minutesPerHour).round();
    return hours < Duration.hoursPerDay ? '${hours}h' : '1d';
  }
  return '${(minutes / Duration.minutesPerDay).round()}d';
}

/// All of the user's recurring tasks. One summary line, then one card per
/// schedule: the prompt, its cadence and the next run, next-to-run first.
class SchedulesPage extends StatelessWidget {
  const SchedulesPage({
    super.key,
    required this.data,
    this.onScheduleTap,
    this.onScheduleMenu,
    this.onToggle,
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
      message: 'Create a schedule to run a task automatically.',
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
    final now = data.now ?? DateTime.now();
    final schedules = data.ordered(now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One line, above the list: how many schedules there are and when the
        // first one runs. The cards below already carry every other detail.
        Padding(
          padding: const EdgeInsets.only(top: OSpace.s),
          child: Text(
            data.summary(now),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
            itemCount: schedules.length,
            itemBuilder: (context, index) {
              final card = _card(context, c, schedules[index], now);
              if (index >= 8) return card;
              final delay = OMotion.stagger * index;
              return OFadeSlide(
                delay: delay > const Duration(milliseconds: 400)
                    ? const Duration(milliseconds: 400)
                    : delay,
                child: card,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _card(
    BuildContext context,
    OColors c,
    V2ScheduleItem schedule,
    DateTime now,
  ) {
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
    final nextRun = schedule.nextRunLabel(now);
    // One line carries the cadence and, when the schedule is on, its next run.
    final meta = [
      if (schedule.ruleLabel.isNotEmpty) schedule.ruleLabel,
      ?nextRun,
    ].join(' · ');
    // The row announces what it shows: the prompt, the cadence, the next run
    // and, when it is off, that it is paused. The switch keeps its own node so
    // its state can still be changed.
    final label = _cardLabel(prompt, schedule, nextRun);

    final card = OCard(
      onTap: onTap == null ? null : () => onTap(schedule),
      semanticLabel: onTap == null ? null : label,
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
                    trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
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
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      // A non-tappable card is not a control: its own text stays readable
      // rather than being wrapped in a second, duplicated label.
      child: card,
    );
  }

  /// One spoken sentence for a card, mirroring the visible content.
  String _cardLabel(String prompt, V2ScheduleItem schedule, String? nextRun) {
    final parts = <String>[
      prompt,
      if (schedule.ruleLabel.isNotEmpty) schedule.ruleLabel,
      if (nextRun != null) 'Next run, $nextRun',
      if (!schedule.enabled) 'Paused',
    ];
    return parts
        .map((part) => part.trim().replaceFirst(RegExp(r'\.$'), ''))
        .join('. ');
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
    final confirmed = await confirmDeleteSchedule(context, schedule.title);
    if (!context.mounted || !confirmed) return;
    onDelete?.call(schedule);
  }
}

/// The one confirmation before a schedule is deleted. Shared by the list and
/// the editor so a destructive action never has two different shapes.
Future<bool> confirmDeleteSchedule(BuildContext context, String title) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete “$title”?'),
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
  return confirmed == true;
}
