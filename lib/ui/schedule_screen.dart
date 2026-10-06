import 'package:flutter/material.dart';

import '../core/agent_notification_service.dart';
import '../core/agent_service.dart';
import '../core/schedule_coordinator.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Schedule screen — Aether redesign.
///
/// Preserves the public widget surface (`ScheduleScreen(sessionId: ...)`),
/// listens on `AppState.I` + `AgentService.I`, and uses the real
/// `editSchedule` / `cancelTask` / `resumeTask` task mutations plus the
/// `AgentNotificationService.stopBackground` / `AgentService.resumeScheduledBackground`
/// background toggle. Status strings {pending, running, paused, failed,
/// completed, cancelled} remain the source of truth.
///
/// The body is the reusable [ScheduleTasksView], also embedded by the
/// Activity hub (which hides this screen's status strip — the hub carries
/// the single strip instead).
class ScheduleScreen extends StatelessWidget {
  final String sessionId;
  const ScheduleScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (context, _) {
        final session = AppState.I.sessionById(sessionId);
        return Scaffold(
          backgroundColor: Aether.bg,
          appBar: AppBar(
            title: Text('Schedule \u00B7 ${session?.title ?? 'session'}'),
          ),
          body: ScheduleTasksView(sessionId: sessionId),
        );
      },
    );
  }
}

/// The scheduled-tasks list: optional background-execution status strip plus
/// one premium card per task (status pill, one-line recurrence/next-run
/// summary, details behind a disclosure, one action menu).
///
/// Embedded standalone by [ScheduleScreen] and, with
/// [showStatusStrip] off, by the Activity hub's Schedules tab so the hub
/// shows one status strip instead of stacked banners.
class ScheduleTasksView extends StatefulWidget {
  final String sessionId;
  final bool showStatusStrip;
  const ScheduleTasksView({
    super.key,
    required this.sessionId,
    this.showStatusStrip = true,
  });

  @override
  State<ScheduleTasksView> createState() => _ScheduleTasksViewState();
}

class _ScheduleTasksViewState extends State<ScheduleTasksView> {
  // No periodic ticker: countdown text refreshes on any state change via the
  // AnimatedBuilder on AppState+AgentService. A tick-based refresh would make
  // pumpAndSettle in widget tests spin forever by scheduling a new frame
  // every tick.

  Future<void> _action(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, agent]),
      builder: (context, _) {
        final session = AppState.I.sessionById(widget.sessionId);
        final tasks = session?.schedules ?? const <Map<String, dynamic>>[];
        final backgroundStopped =
            agent.schedules.stopped || AgentNotificationService.I.backgroundStopped;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (widget.showStatusStrip) ...[
              _statusStrip(context, backgroundStopped),
              const SizedBox(height: 20),
            ],
            const AetherSectionTitle(eyebrow: 'Scheduled tasks'),
            const SizedBox(height: 12),
            if (tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: AetherEmptyState(
                  icon: Icons.schedule,
                  title: 'No scheduled tasks',
                  message:
                      'Ask the agent to schedule a daily, recurring, or one-off task.',
                ),
              )
            else
              for (final task in tasks) ...[
                _TaskCard(
                  key: ValueKey(task['id'] ?? task),
                  entry: ScheduleEntry(widget.sessionId, task),
                  onEdit: () => _edit(
                    context,
                    ScheduleEntry(widget.sessionId, task),
                  ),
                  onAction: _action,
                ),
                const SizedBox(height: 12),
              ],
          ],
        );
      },
    );
  }

  Widget _statusStrip(BuildContext context, bool backgroundStopped) {
    final notes = <String>[];
    final constraint = AgentNotificationService.I.backgroundConstraint;
    if (constraint != null && constraint.isNotEmpty) {
      notes.add('System constraint: $constraint');
    }
    if (!AppState.I.keepAliveEnabled) {
      notes.add(
        'Background keep-alive is off. Future tasks may wait until you reopen Ovid.',
      );
    }
    if (!AppState.I.notificationsEnabled) {
      notes.add(
        'Notifications are off; background service visibility is unavailable.',
      );
    }
    final headline = backgroundStopped
        ? 'Background execution paused'
        : 'Background execution active';
    final dotColor = backgroundStopped ? Aether.warn : Aether.success;
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AetherStatusDot(color: dotColor, pulsing: !backgroundStopped),
              const SizedBox(width: 10),
              Expanded(child: Text(headline, style: AetherType.title)),
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('\u2022  ', style: AetherType.caption),
                    Expanded(child: Text(note, style: AetherType.caption)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(backgroundStopped ? Icons.play_arrow : Icons.stop),
              label: Text(backgroundStopped
                  ? 'Resume background execution'
                  : 'Stop background execution'),
              onPressed: () => _action(
                context,
                backgroundStopped
                    ? AgentService.I.resumeScheduledBackground
                    : AgentNotificationService.I.stopBackground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, ScheduleEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _EditScheduleSheet(entry: entry),
    );
  }
}

/// Owns its own TextEditingController lifecycle so controllers aren't disposed
/// while the modal route is still animating out and the parent AnimatedBuilder
/// could rebuild referencing them.
class _EditScheduleSheet extends StatefulWidget {
  final ScheduleEntry entry;
  const _EditScheduleSheet({required this.entry});

  @override
  State<_EditScheduleSheet> createState() => _EditScheduleSheetState();
}

class _EditScheduleSheetState extends State<_EditScheduleSheet> {
  late final TextEditingController _prompt;
  late final TextEditingController _time;
  late String _kind;
  late int _retries;
  String? _error;
  String? _promptError;
  String? _timeError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.entry.task;
    _kind = t['dailyAt'] != null
        ? 'daily_at'
        : t['every'] != null
            ? 'every_seconds'
            : 'at';
    _prompt = TextEditingController(text: (t['prompt'] as String?) ?? '');
    _time = TextEditingController(
      text: '${t['dailyAt'] ?? t['every'] ?? t['fireAt'] ?? ''}',
    );
    final maxRetries = (t['maxRetries'] as int?) ?? 0;
    _retries = maxRetries.clamp(0, 3);
  }

  @override
  void dispose() {
    _prompt.dispose();
    _time.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final time = _time.text.trim();
    String? timeError;
    if (_kind == 'daily_at') {
      if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
        timeError = 'Use HH:mm, from 00:00 to 23:59.';
      }
    } else if (_kind == 'every_seconds') {
      if ((int.tryParse(time) ?? -1) < 300) {
        timeError = 'Enter a whole number of seconds, at least 300.';
      }
    } else {
      try {
        ScheduleCoordinator.parseDate(time);
      } on FormatException catch (e) {
        timeError = e.message;
      }
    }
    setState(() {
      _error = null;
      _promptError = _prompt.text.trim().isEmpty ? 'Enter a task description.' : null;
      _timeError = timeError;
    });
    if (_promptError != null || _timeError != null) return;
    setState(() => _saving = true);
    try {
      final value = _kind == 'every_seconds'
          ? int.parse(time)
          : time;
      await AgentService.I.editSchedule(widget.entry, {
        'prompt': _prompt.text,
        _kind: value,
        'max_retries': _retries,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _timeLabel() => switch (_kind) {
        'daily_at' => 'Time HH:mm',
        'every_seconds' => 'Interval seconds (>=300)',
        _ => 'Date/time YYYY-MM-DD HH:mm',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: AetherSheet(
        title: 'Edit schedule',
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AetherField(
                label: 'Task',
                fieldKey: const ValueKey('schedule-prompt'),
                controller: _prompt,
                enabled: !_saving,
                errorText: _promptError,
                maxLines: 4,
              ),
              const SizedBox(height: 16),
              Text('Recurrence', style: AetherType.label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in const [
                    (value: 'at', label: 'One-off'),
                    (value: 'daily_at', label: 'Daily'),
                    (value: 'every_seconds', label: 'Interval'),
                  ])
                    ChoiceChip(
                      label: Text(option.label),
                      selected: _kind == option.value,
                      onSelected: _saving ? null : (_) => setState(() {
                        if (_kind == option.value) return;
                        _kind = option.value;
                        _time.clear();
                        _timeError = null;
                        _error = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              AetherField(
                fieldKey: const ValueKey('schedule-time'),
                label: _timeLabel(),
                controller: _time,
                enabled: !_saving,
                errorText: _timeError,
                keyboardType: _kind == 'every_seconds'
                    ? TextInputType.number
                    : _kind == 'daily_at' ? TextInputType.datetime : TextInputType.text,
                helper: switch (_kind) {
                  'daily_at' => 'Repeats in device-local time. Follows device time zone changes.',
                  'every_seconds' => 'Fixed interval; minimum 300 seconds (5 minutes).',
                  _ => 'Device-local time unless you include Z or an offset, e.g. +05:30. Past times are due immediately.',
                },
              ),
              const SizedBox(height: 16),
              AetherStepper(
                label: 'Safe retries',
                value: _retries,
                min: 0,
                max: 3,
                onChanged: (v) {
                  if (!_saving) setState(() => _retries = v);
                },
              ),
              const SizedBox(height: 6),
              Text('Only failures before execution are safe to retry.', style: AetherType.caption),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Aether.dangerC,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A card representing a single scheduled task.
class _TaskCard extends StatefulWidget {
  final ScheduleEntry entry;
  final VoidCallback onEdit;
  final Future<void> Function(
    BuildContext context,
    Future<void> Function() action,
  ) onAction;

  const _TaskCard({
    super.key,
    required this.entry,
    required this.onEdit,
    required this.onAction,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.entry.task;
    final status = (t['status'] as String?) ?? 'pending';
    final prompt = (t['prompt'] as String?) ?? '';
    final next = _scheduledTime(t);
    final agent = AgentService.I;

    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AetherPill(
                label: status,
                color: _statusColor(status),
                filled: status != 'completed' && status != 'cancelled',
              ),
              const Spacer(),
              _menu(context, status, agent),
            ],
          ),
          const SizedBox(height: 8),
          Text(prompt.isEmpty ? '(empty)' : prompt,
              style: AetherType.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 10),
          Text(_prettyRecurrence(t), style: AetherType.bodyMuted),
          const SizedBox(height: 4),
          Text(
            _secondary(status, next, t),
            style: AetherType.bodyMuted,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
              label: Text(_expanded ? 'Hide details' : 'Show details'),
              onPressed: () => setState(() => _expanded = !_expanded),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            _details(t),
          ],
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, String status, AgentService agent) {
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'edit',
        enabled: status != 'running',
        child: Text('Edit', style: AetherType.body),
      ),
      if (status == 'pending' || status == 'running')
        PopupMenuItem<String>(
          value: 'pause',
          child: Text('Pause', style: AetherType.body),
        ),
      if (status == 'paused' || status == 'failed')
        PopupMenuItem<String>(
          value: 'resume',
          child: Text('Resume', style: AetherType.body),
        ),
      if (status != 'cancelled' && status != 'completed')
        PopupMenuItem<String>(
          value: 'cancel',
          child: Text('Cancel', style: AetherType.body),
        ),
    ];
    return PopupMenuButton<String>(
      tooltip: 'Task actions',
      icon: Icon(Icons.more_horiz, color: Aether.textMuted),
      itemBuilder: (_) => items,
      onSelected: (choice) {
        switch (choice) {
          case 'edit':
            widget.onEdit();
          case 'pause':
            widget.onAction(
              context,
              () => agent.schedules.cancelTask(widget.entry, pause: true),
            );
          case 'resume':
            widget.onAction(
              context,
              () => agent.schedules.resumeTask(widget.entry),
            );
          case 'cancel':
            widget.onAction(
              context,
              () => agent.schedules.cancelTask(widget.entry),
            );
        }
      },
    );
  }

  Widget _details(Map<String, dynamic> t) {
    final status = (t['status'] as String?) ?? 'pending';
    final prompt = (t['prompt'] as String?) ?? '';
    final next = _scheduledTime(t);
    final attempt = t['attempt'] ?? 0;
    final max = t['maxRetries'] ?? 0;
    final lastStatus = t['lastStatus'];
    final lastRunAt =
        DateTime.tryParse('${t['finishedAt'] ?? t['lastRunAt'] ?? ''}')?.toLocal();
    final startedAt = DateTime.tryParse('${t['startedAt'] ?? ''}')?.toLocal();
    final error = t['error'];
    final raw = _rawSpec(t);
    final scheduledLabel = next != null
        ? _fmtInstant(next)
        : 'Not scheduled';
    final nextRunLabel = status == 'pending' && next != null
        ? _nextRunLabel(next)
        : _executionLabel(status);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Description', style: AetherType.label),
        const SizedBox(height: 4),
        Text(
          prompt.isEmpty ? '(empty)' : prompt,
          style: AetherType.body,
        ),
        const SizedBox(height: 10),
        _detailRow('Scheduled', scheduledLabel),
        _detailRow('Time zone', next == null
            ? 'Unavailable'
            : '${_zoneLabel(next)} · device-local display'),
        _detailRow('Recurrence', _prettyRecurrence(t)),
        _detailRow('Next run', nextRunLabel),
        _detailRow(
          'Last run',
          lastStatus == null
              ? (startedAt != null || lastRunAt != null ? 'No result recorded' : 'Never run')
              : (lastRunAt == null
                  ? '$lastStatus'
                  : '$lastStatus \u00B7 ${_fmtInstant(lastRunAt)}'),
        ),
        if (startedAt != null) _detailRow('Started', _fmtInstant(startedAt)),
        if (lastStatus == null && lastRunAt != null)
          _detailRow('Finished', _fmtInstant(lastRunAt)),
        _detailRow(
          'Retries',
          '$attempt/$max \u00B7 pre-execution failures only',
        ),
        if (error != null) _detailRow('Last error', '$error'),
        const SizedBox(height: 8),
        Text('Raw spec', style: AetherType.label),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Aether.codeBg,
            borderRadius: BorderRadius.circular(AetherRadius.rSm),
            border: Border.all(color: Aether.hairline),
          ),
          child: Text(raw, style: AetherType.mono),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final labelText = Text(label, style: AetherType.label);
          final valueText = Text(value, style: AetherType.bodyMuted);
          if (constraints.maxWidth < 520 || MediaQuery.textScalerOf(context).scale(14) > 20) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, const SizedBox(height: 4), valueText],
              ),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 120, child: labelText),
              Expanded(child: valueText),
            ],
          );
        },
      ),
    );
  }

  String _nextRunLabel(DateTime next) {
    final now = DateTime.now();
    final diff = next.difference(now);
    if (diff.isNegative) {
      return 'Overdue by ${_fmtDuration(diff.abs())} '
          '\u00B7 ${_fmtInstant(next)}';
    }
    return 'In ${_fmtDuration(diff)} \u00B7 ${_fmtInstant(next)}';
  }

  String _secondary(
    String status,
    DateTime? next,
    Map<String, dynamic> t,
  ) {
    if (status == 'pending' && next != null) {
      final now = DateTime.now();
      final diff = next.difference(now);
      if (diff.isNegative) {
        return 'Overdue by ${_fmtDuration(diff.abs())} · ${_fmtInstant(next)}';
      }
      return 'Next in ${_fmtDuration(diff)} · ${_fmtInstant(next)}';
    }
    final last = t['lastStatus'];
    return '${_executionLabel(status)}${last != null ? ' · Last run: $last' : ''}';
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'running':
        return Aether.success;
      case 'paused':
        return Aether.warn;
      case 'failed':
        return Aether.danger;
      case 'completed':
      case 'cancelled':
        return Aether.textFaint;
      case 'pending':
      default:
        return Aether.accent;
    }
  }
}

// Match ScheduleCoordinator's due-time rules: daily calendar occurrences move
// with the device zone, but an in-flight retry keeps its persisted instant.
DateTime? _scheduledTime(Map<String, dynamic> t) {
  if (t['dailyAt'] != null && t['localDate'] != null && (t['attempt'] ?? 0) == 0) {
    return DateTime.tryParse('${t['localDate']}T${t['dailyAt']}:00')?.toLocal();
  }
  return DateTime.tryParse('${t['fireAt'] ?? ''}')?.toLocal();
}

String _executionLabel(String status) => switch (status) {
  'paused' => 'Paused · resume to run',
  'running' => 'Execution in progress',
  'failed' => 'Failed · review before resuming',
  'completed' => 'Completed · no next run',
  'cancelled' => 'Cancelled · no next run',
  _ => 'Not scheduled',
};

String _zoneLabel(DateTime time) {
  final minutes = time.timeZoneOffset.inMinutes;
  final hours = (minutes.abs() ~/ 60).toString().padLeft(2, '0');
  final remainder = (minutes.abs() % 60).toString().padLeft(2, '0');
  final offset = 'UTC${minutes < 0 ? '-' : '+'}$hours:$remainder';
  // A runtime abbreviation is not an IANA zone ID; do not manufacture one.
  return time.timeZoneName.isEmpty ? offset : '${time.timeZoneName} ($offset)';
}

String _rawSpec(Map<String, dynamic> t) {
  if (t['dailyAt'] != null) return 'dailyAt=${t['dailyAt']}';
  if (t['every'] != null) return 'every=${t['every']}s';
  if (t['fireAt'] != null) return 'fireAt=${t['fireAt']}';
  return 'spec=unknown';
}

String _prettyRecurrence(Map<String, dynamic> t) {
  if (t['dailyAt'] != null) {
    return 'Daily \u00B7 ${t['dailyAt']} \u00B7 device-local time';
  }
  if (t['every'] != null) {
    final seconds = (t['every'] as num?)?.toInt() ?? 0;
    return 'Every ${_fmtInterval(seconds)} \u00B7 fixed interval';
  }
  final fireAt = DateTime.tryParse((t['fireAt'] as String?) ?? '')?.toLocal();
  if (fireAt == null) return 'One-off \u00B7 unknown';
  return 'One-off \u00B7 ${_fmtInstant(fireAt)}';
}

String _fmtInterval(int seconds) {
  if (seconds <= 0) return '0s';
  if (seconds % 86400 == 0) return '${seconds ~/ 86400} d';
  if (seconds % 3600 == 0) return '${seconds ~/ 3600} h';
  if (seconds % 60 == 0) return '${seconds ~/ 60} min';
  return '$seconds s';
}

String _fmtDuration(Duration d) {
  if (d.inDays >= 1) {
    final hours = d.inHours % 24;
    return hours == 0 ? '${d.inDays}d' : '${d.inDays}d ${hours}h';
  }
  if (d.inHours >= 1) {
    final minutes = d.inMinutes % 60;
    return minutes == 0
        ? '${d.inHours}h'
        : '${d.inHours}h ${minutes}m';
  }
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}

String _fmtInstant(DateTime dt) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour12 = dt.hour == 0
      ? 12
      : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
  final suffix = dt.hour >= 12 ? 'PM' : 'AM';
  final minute = dt.minute.toString().padLeft(2, '0');
  final seconds = dt.second == 0 ? '' : ':${dt.second.toString().padLeft(2, '0')}';
  return '${months[dt.month - 1]} ${dt.day}, ${dt.year} at '
      '$hour12:$minute$seconds $suffix ${_zoneLabel(dt)}';
}
