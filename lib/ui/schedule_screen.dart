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
class ScheduleScreen extends StatefulWidget {
  final String sessionId;
  const ScheduleScreen({super.key, required this.sessionId});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
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

        return Scaffold(
          backgroundColor: Aether.bg,
          appBar: AppBar(
            title: Text('Schedule \u00B7 ${session?.title ?? 'session'}'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _statusStrip(context, backgroundStopped),
              const SizedBox(height: 20),
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
                  ),
                  const SizedBox(height: 12),
                ],
            ],
          ),
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

  /// Raw value in the coordinator's stored format (HH:mm, seconds, or a
  /// date/time). The pickers write into it; it is editable directly only
  /// under "Advanced".
  late final TextEditingController _time;
  late final TextEditingController _intervalValue;
  ScheduleIntervalUnit _intervalUnit = ScheduleIntervalUnit.minutes;
  late String _kind;
  late int _retries;
  late final Map<String, String> _draftTimes;
  String? _error;
  String? _promptError;
  String? _timeError;
  bool _saving = false;

  /// Raw-text editing ("Advanced") is collapsed by default.
  bool _advanced = false;

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
    _draftTimes = {
      'daily_at': t['dailyAt']?.toString() ?? '',
      'every_seconds': t['every']?.toString() ?? '',
      // Stored one-offs are UTC ISO strings ("…Z"); edit them in local time.
      'at': scheduleLocalText(t['fireAt']?.toString() ?? ''),
    };
    _time = TextEditingController(text: _draftTimes[_kind]);
    _intervalValue = TextEditingController();
    _syncIntervalFromRaw();
    final maxRetries = (t['maxRetries'] as int?) ?? 0;
    _retries = maxRetries.clamp(0, 3);
  }

  @override
  void dispose() {
    _prompt.dispose();
    _time.dispose();
    _intervalValue.dispose();
    super.dispose();
  }

  /// Raw seconds → number + unit (largest unit that divides evenly).
  void _syncIntervalFromRaw() {
    final seconds = int.tryParse(_draftTimes['every_seconds'] ?? '');
    if (_kind == 'every_seconds') {
      final raw = int.tryParse(_time.text.trim());
      if (raw != null) {
        _setInterval(raw);
        return;
      }
    }
    if (seconds != null) {
      _setInterval(seconds);
    } else {
      _intervalValue.text = '';
    }
  }

  void _setInterval(int seconds) {
    final (value, unit) = splitScheduleInterval(seconds);
    _intervalUnit = unit;
    _intervalValue.text = value;
  }

  /// Number + unit → raw seconds.
  void _syncRawFromInterval() {
    final n = num.tryParse(_intervalValue.text.trim());
    _time.text = n == null
        ? ''
        : (n * _intervalUnit.seconds).round().toString();
  }

  Future<void> _pickDailyTime() async {
    final current =
        _parseHm(_time.text.trim()) ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = '${_two(picked.hour)}:${_two(picked.minute)}';
      _timeError = null;
    });
  }

  DateTime? _oneOffLocal() {
    final text = _time.text.trim();
    if (text.isEmpty) return null;
    try {
      return ScheduleCoordinator.parseDate(text).toLocal();
    } on FormatException {
      return null;
    }
  }

  DateTime _oneOffSeed() {
    final current = _oneOffLocal();
    if (current != null) return current;
    final now = DateTime.now().add(const Duration(hours: 1));
    return DateTime(now.year, now.month, now.day, now.hour);
  }

  Future<void> _pickOneOffDate() async {
    final seed = _oneOffSeed();
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: seed.isBefore(first) ? first : seed,
      firstDate: seed.isBefore(first)
          ? DateTime(seed.year, seed.month, seed.day)
          : first,
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = formatScheduleLocal(
        DateTime(picked.year, picked.month, picked.day, seed.hour, seed.minute),
      );
      _timeError = null;
    });
  }

  Future<void> _pickOneOffTime() async {
    final seed = _oneOffSeed();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(seed),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _time.text = formatScheduleLocal(
        DateTime(seed.year, seed.month, seed.day, picked.hour, picked.minute),
      );
      _timeError = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final time = _time.text.trim();
    String? timeError;
    if (_kind == 'daily_at') {
      if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(time)) {
        timeError = 'Pick a time of day (HH:mm, 00:00 to 23:59).';
      }
    } else if (_kind == 'every_seconds') {
      final seconds = int.tryParse(time);
      if (seconds == null) {
        timeError = 'Enter how often to run, e.g. 15 minutes.';
      } else if (seconds < minScheduleIntervalSeconds) {
        timeError = 'The shortest interval is 5 minutes.';
      }
    } else {
      try {
        ScheduleCoordinator.parseDate(time);
      } on FormatException catch (e) {
        timeError = time.isEmpty ? 'Pick a date and time.' : e.message;
      }
    }
    setState(() {
      _error = null;
      _promptError = _prompt.text.trim().isEmpty
          ? 'Enter a task description.'
          : null;
      _timeError = timeError;
    });
    if (_promptError != null || _timeError != null) return;
    setState(() => _saving = true);
    try {
      final value = _kind == 'every_seconds' ? int.parse(time) : time;
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
    'every_seconds' => 'Interval in seconds (300 or more)',
    _ => 'Date/time YYYY-MM-DD HH:mm',
  };

  Widget _pickerButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) => OutlinedButton.icon(
    key: key,
    onPressed: _saving ? null : onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );

  Widget _primaryTimeControl(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final errorText = _timeError == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _timeError!,
                key: const ValueKey('schedule-time-error'),
                style: TextStyle(color: Aether.dangerC, fontSize: 12),
              ),
            ),
          );
    switch (_kind) {
      case 'daily_at':
        final t = _parseHm(_time.text.trim());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pickerButton(
              key: const ValueKey('schedule-daily-time'),
              icon: Icons.schedule,
              label: t == null ? 'Pick a time' : l10n.formatTimeOfDay(t),
              onPressed: _pickDailyTime,
            ),
            const SizedBox(height: 4),
            Text(
              'Repeats every day in device-local time.',
              style: AetherType.caption,
            ),
            ?errorText,
          ],
        );
      case 'every_seconds':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: AetherField(
                    fieldKey: const ValueKey('schedule-interval-value'),
                    label: 'Every',
                    controller: _intervalValue,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {
                      _syncRawFromInterval();
                      _timeError = null;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<ScheduleIntervalUnit>(
                  key: const ValueKey('schedule-interval-unit'),
                  value: _intervalUnit,
                  onChanged: _saving
                      ? null
                      : (u) {
                          if (u == null) return;
                          setState(() {
                            _intervalUnit = u;
                            _syncRawFromInterval();
                            _timeError = null;
                          });
                        },
                  items: [
                    for (final u in ScheduleIntervalUnit.values)
                      DropdownMenuItem(value: u, child: Text(u.label)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('Minimum 5 minutes.', style: AetherType.caption),
            ?errorText,
          ],
        );
      default:
        final local = _oneOffLocal();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pickerButton(
                  key: const ValueKey('schedule-oneoff-date'),
                  icon: Icons.calendar_today_outlined,
                  label: local == null
                      ? 'Pick a date'
                      : l10n.formatMediumDate(local),
                  onPressed: _pickOneOffDate,
                ),
                _pickerButton(
                  key: const ValueKey('schedule-oneoff-time'),
                  icon: Icons.schedule,
                  label: local == null
                      ? 'Pick a time'
                      : l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local)),
                  onPressed: _pickOneOffTime,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Device-local time. A time in the past runs right away.',
              style: AetherType.caption,
            ),
            ?errorText,
          ],
        );
    }
  }

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
                // Keep the primary action reachable on compact viewports.
                maxLines: 2,
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
                      onSelected: _saving
                          ? null
                          : (_) => setState(() {
                              if (_kind == option.value) return;
                              _draftTimes[_kind] = _time.text;
                              _kind = option.value;
                              _time.text = _draftTimes[_kind] ?? '';
                              if (_kind == 'every_seconds') {
                                _syncIntervalFromRaw();
                              }
                              _timeError = null;
                              _error = null;
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _primaryTimeControl(context),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('schedule-advanced'),
                  onPressed: () => setState(() => _advanced = !_advanced),
                  icon: Icon(
                    _advanced ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: const Text('Advanced'),
                ),
              ),
              if (_advanced) ...[
                AetherField(
                  fieldKey: const ValueKey('schedule-time'),
                  label: _timeLabel(),
                  controller: _time,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {
                    _timeError = null;
                    if (_kind == 'every_seconds') {
                          _syncIntervalFromRaw();
                        }
                  }),
                  keyboardType: _kind == 'every_seconds'
                      ? TextInputType.number
                      : _kind == 'daily_at'
                      ? TextInputType.datetime
                      : TextInputType.text,
                  helper: switch (_kind) {
                    'daily_at' =>
                      'Repeats in device-local time. Follows device time zone changes.',
                    'every_seconds' =>
                      'Fixed interval; minimum 300 seconds (5 minutes).',
                    _ =>
                      'Device-local time unless you include Z or an offset, e.g. +05:30. Past times are due immediately.',
                  },
                ),
                const SizedBox(height: 8),
              ],
              Text('Preview', style: AetherType.label),
              const SizedBox(height: 4),
              Text(
                _previewLabel(context),
                key: const ValueKey('schedule-preview'),
                style: AetherType.caption,
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
              Text(
                'Only failures before execution are safe to retry.',
                style: AetherType.caption,
              ),
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

  String _previewLabel(BuildContext context) {
    final value = _time.text.trim();
    if (value.isEmpty) return 'Choose when to run to preview the next run.';
    final l10n = MaterialLocalizations.of(context);
    switch (_kind) {
      case 'daily_at':
        final t = _parseHm(value);
        return t == null
            ? 'Runs daily at $value in device-local time.'
            : 'Runs daily at ${l10n.formatTimeOfDay(t)} in device-local time.';
      case 'every_seconds':
        final seconds = int.tryParse(value);
        if (seconds == null) {
          return 'Runs every $value seconds after the next save.';
        }
        return 'Runs every ${describeScheduleInterval(seconds)} after the next save.';
      default:
        final local = _oneOffLocal();
        if (local == null) return 'Runs once at $value.';
        return 'Runs once on ${l10n.formatMediumDate(local)} at '
            '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))} (device-local time).';
    }
  }
}

String _two(int v) => v.toString().padLeft(2, '0');

TimeOfDay? _parseHm(String value) {
  final m = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$').firstMatch(value);
  if (m == null) return null;
  return TimeOfDay(hour: int.parse(m[1]!), minute: int.parse(m[2]!));
}

/// Shortest allowed interval (the coordinator's floor).
const minScheduleIntervalSeconds = 300;

enum ScheduleIntervalUnit {
  minutes('minutes', 60),
  hours('hours', 3600),
  days('days', 86400);

  const ScheduleIntervalUnit(this.label, this.seconds);
  final String label;
  final int seconds;
}

/// Seconds → (number text, unit), using the largest unit that divides
/// evenly (falls back to fractional minutes for odd raw values).
@visibleForTesting
(String, ScheduleIntervalUnit) splitScheduleInterval(int seconds) {
  for (final u in ScheduleIntervalUnit.values.reversed) {
    if (seconds > 0 && seconds % u.seconds == 0) {
      return ((seconds ~/ u.seconds).toString(), u);
    }
  }
  final minutes = seconds / 60;
  return (
    minutes == minutes.roundToDouble()
        ? minutes.round().toString()
        : minutes.toStringAsFixed(2),
    ScheduleIntervalUnit.minutes,
  );
}

/// "15 minutes", "2 hours", "1 day".
@visibleForTesting
String describeScheduleInterval(int seconds) {
  final (value, unit) = splitScheduleInterval(seconds);
  final label = value == '1'
      ? unit.label.substring(0, unit.label.length - 1)
      : unit.label;
  return '$value $label';
}

/// Local `YYYY-MM-DD HH:mm` (the coordinator reads a value without Z or an
/// offset as device-local time).
@visibleForTesting
String formatScheduleLocal(DateTime local) =>
    '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-${_two(local.day)} '
    '${_two(local.hour)}:${_two(local.minute)}'
    '${local.second != 0 ? ':${_two(local.second)}' : ''}';

/// Stored one-off value (usually UTC `…Z`) → editable local text. Values that
/// do not parse are returned unchanged.
@visibleForTesting
String scheduleLocalText(String stored) {
  if (stored.trim().isEmpty) return '';
  try {
    return formatScheduleLocal(
      ScheduleCoordinator.parseDate(stored.trim()).toLocal(),
    );
  } on FormatException {
    return stored;
  }
}

/// A card representing a single scheduled task.
class _TaskCard extends StatefulWidget {
  final ScheduleEntry entry;
  final VoidCallback onEdit;

  const _TaskCard({
    super.key,
    required this.entry,
    required this.onEdit,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;
  bool _busy = false;
  String? _feedback;

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
          if (status == 'failed' || status == 'paused') ...[
            const SizedBox(height: 8),
            Text(
              status == 'failed' ? 'Recovery needed' : 'Paused · recovery available',
              style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w600),
            ),
            if (t['error'] != null)
              Text('${t['error']}', style: AetherType.caption),
          ],
          const SizedBox(height: 4),
          Text(
            _secondary(status, next, t),
            style: AetherType.bodyMuted,
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 6),
            Text('Updating schedule…', style: AetherType.caption),
          ],
          if (_feedback != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(_feedback!, style: AetherType.caption),
            ),
          ],
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
            _runAction(() => agent.schedules.cancelTask(widget.entry, pause: true));
          case 'resume':
            _runAction(() => agent.schedules.resumeTask(widget.entry));
          case 'cancel':
            _runAction(() => agent.schedules.cancelTask(widget.entry));
        }
      },
    );
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      if (mounted) setState(() => _feedback = 'Schedule updated.');
    } catch (e) {
      if (mounted) setState(() => _feedback = 'Could not update schedule: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
