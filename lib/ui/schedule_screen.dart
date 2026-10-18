import 'package:flutter/material.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/schedule_client.dart';
import '../core/diag.dart';
import '../core/distribution.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

/// Friendly copy for a failed schedule mutation. P4 errors carry a
/// user-readable `message` (spec §15), so it is surfaced verbatim; local
/// validation failures get the generic invalid copy. The raw error is logged
/// to [Diag], never shown.
String scheduleFailure(
  AppLocalizations l,
  Object error, [
  StackTrace? stack,
  String log = 'schedule_screen',
]) {
  Diag.swallow(log, error, stack);
  if (error is CloudApiException) return error.message;
  if (error is FormatException) return l.scheduleErrorInvalid;
  return friendlyError(error, l10n: l);
}

/// Schedule screen — server-backed (P4 REST).
///
/// The widget tree is the Aether redesign; the data bindings now come from
/// [ScheduleClient] (`GET/PATCH/DELETE /schedules`, `GET /schedules/:id/runs`)
/// instead of the deleted local `ScheduleCoordinator` runtime. Rows are
/// filtered to [sessionId] because the server list is account-wide.
///
/// When `Distribution.cloudSchedules` is false (a build without the thin
/// client) the local runtime no longer exists, so the screen shows the
/// cloud-empty state rather than pretending to schedule locally.
class ScheduleScreen extends StatefulWidget {
  final String sessionId;
  const ScheduleScreen({super.key, required this.sessionId});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  List<ScheduleDto> _schedules = const <ScheduleDto>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (Distribution.cloudSchedules) {
      _load();
    } else {
      _loading = false;
    }
  }

  Future<void> _load() async {
    if (!Distribution.cloudSchedules) return;
    if (mounted) setState(() => _error = null);
    try {
      final all = await ScheduleClient.I.list(includeCancelled: true);
      if (!mounted) return;
      setState(() {
        _schedules = all
            .where((s) => s.sessionId == widget.sessionId)
            .toList(growable: false);
        _loading = false;
      });
    } catch (e, st) {
      Diag.swallow('schedule_screen.load', e, st);
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, l10n: context.l10n);
        _loading = false;
      });
    }
  }

  Future<void> _edit(BuildContext context, ScheduleDto schedule) async {
    await showAetherSheet<void>(
      context: context,
      builder: (sheetContext) => _EditScheduleSheet(schedule: schedule),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final session = AppState.I.sessionById(widget.sessionId);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        title: Text('Schedule · ${session?.title ?? 'session'}'),
      ),
      body: !Distribution.cloudSchedules
          ? _cloudUnavailable(context)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _statusStrip(context),
                  const SizedBox(height: 20),
                  const AetherSectionTitle(eyebrow: 'Scheduled tasks'),
                  const SizedBox(height: 12),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    _errorState(context)
                  else if (_schedules.isEmpty)
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
                    for (final schedule in _schedules) ...[
                      _TaskCard(
                        key: ValueKey(schedule.id),
                        schedule: schedule,
                        onChanged: _load,
                        onEdit: () => _edit(context, schedule),
                      ),
                      const SizedBox(height: 12),
                    ],
                ],
              ),
            ),
    );
  }

  Widget _cloudUnavailable(BuildContext context) {
    final l = context.l10n;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
      children: [
        AetherEmptyState(
          icon: Icons.cloud_off,
          title: l.scheduleCloudEmptyTitle,
          message: l.scheduleCloudEmptyMessage,
        ),
      ],
    );
  }

  Widget _errorState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: AetherCard(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.scheduleLoadErrorTitle, style: AetherType.title),
            const SizedBox(height: 6),
            Text(_error!, style: AetherType.bodyMuted),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: Text(context.l10n.actionRetry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusStrip(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AetherStatusDot(color: Aether.success, pulsing: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.l10n.scheduleCloudActive,
                  style: AetherType.title,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.l10n.scheduleCloudActiveMessage,
            style: AetherType.caption,
          ),
        ],
      ),
    );
  }
}

/// Owns its own TextEditingController lifecycle so controllers aren't disposed
/// while the modal route is still animating out.
class _EditScheduleSheet extends StatefulWidget {
  final ScheduleDto schedule;
  const _EditScheduleSheet({required this.schedule});

  @override
  State<_EditScheduleSheet> createState() => _EditScheduleSheetState();
}

class _EditScheduleSheetState extends State<_EditScheduleSheet> {
  late final TextEditingController _title;
  late final TextEditingController _description;

  /// Raw value in the trigger's stored format (HH:mm, seconds, cron expr, or
  /// a date/time). The pickers write into it; it is editable directly only
  /// under "Advanced".
  late final TextEditingController _time;
  late final TextEditingController _intervalValue;
  ScheduleIntervalUnit _intervalUnit = ScheduleIntervalUnit.minutes;
  late String _kind;

  /// IANA zone preserved from the original trigger (daily/cron). Null until a
  /// save needs one, then the device zone is resolved.
  String? _tz;
  late int _retries;
  late final Map<String, String> _draftTimes;
  String? _error;
  String? _titleError;
  String? _descriptionError;
  String? _timeError;
  bool _saving = false;

  /// Raw-text editing ("Advanced") is collapsed by default.
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    final s = widget.schedule;
    final trigger = s.trigger;
    _kind = switch (trigger.kind) {
      'daily_at' => 'daily_at',
      'every' => 'every_seconds',
      'cron' => 'cron',
      _ => 'at',
    };
    _tz = trigger.tz;
    _title = TextEditingController(text: s.title);
    _description = TextEditingController(text: s.description);
    _draftTimes = {
      'daily_at': trigger.kind == 'daily_at' ? (trigger.time ?? '') : '',
      'every_seconds':
          trigger.kind == 'every' ? '${trigger.seconds ?? ''}' : '',
      'cron': trigger.kind == 'cron' ? (trigger.expr ?? '') : '',
      // Stored one-offs are UTC instants; edit them in local time.
      'at': trigger.kind == 'at' && trigger.at != null
          ? formatScheduleLocal(trigger.at!.toLocal())
          : '',
    };
    _time = TextEditingController(text: _draftTimes[_kind]);
    _intervalValue = TextEditingController();
    _syncIntervalFromRaw();
    _retries = s.maxRetries.clamp(0, 3);
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
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
      return ScheduleClient.parseDate(text).toLocal();
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
    final title = _title.text.trim();
    final description = _description.text.trim();
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
    } else if (_kind == 'cron') {
      if (time.trim().split(RegExp(r'\s+')).length != 5) {
        timeError = 'Enter a 5-field cron expression.';
      }
    } else {
      try {
        ScheduleClient.parseDate(time);
      } on FormatException catch (e) {
        timeError = time.isEmpty ? 'Pick a date and time.' : e.message;
      }
    }
    setState(() {
      _error = null;
      _titleError = title.isEmpty ? 'Enter a title.' : null;
      _descriptionError =
          description.isEmpty ? 'Enter a task description.' : null;
      _timeError = timeError;
    });
    if (_titleError != null || _descriptionError != null || _timeError != null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final ScheduleTrigger trigger;
      switch (_kind) {
        case 'daily_at':
          final tz = _tz ?? await ScheduleClient.deviceTimeZone();
          trigger = ScheduleTrigger.dailyAt(time, tz: tz);
        case 'every_seconds':
          trigger = ScheduleTrigger.every(int.parse(time));
        case 'cron':
          final tz = _tz ?? await ScheduleClient.deviceTimeZone();
          trigger = ScheduleTrigger.cron(time, tz: tz);
        default:
          trigger = ScheduleTrigger.at(
            ScheduleClient.parseDate(time).toUtc(),
          );
      }
      await ScheduleClient.I.update(
        widget.schedule.id,
        title: title,
        description: description,
        trigger: trigger,
        maxRetries: _retries,
      );
      if (mounted) Navigator.pop(context);
    } catch (e, st) {
      if (mounted) {
        setState(
          () => _error =
              scheduleFailure(context.l10n, e, st, 'schedule_screen.edit'),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _timeLabel() => switch (_kind) {
    'daily_at' => 'Time HH:mm',
    'every_seconds' => 'Interval in seconds (300 or more)',
    'cron' => 'Cron expression (5 fields)',
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
              'Repeats every day in ${_tz ?? 'the device time zone'}.',
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
            Text(context.l10n.scheduleMinimumInterval, style: AetherType.caption),
            ?errorText,
          ],
        );
      case 'cron':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AetherField(
              fieldKey: const ValueKey('schedule-cron'),
              label: context.l10n.scheduleCronLabel,
              controller: _time,
              enabled: !_saving,
              onChanged: (_) => setState(() => _timeError = null),
              helper: context.l10n.scheduleCronHelper,
            ),
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
                label: 'Title',
                fieldKey: const ValueKey('schedule-title'),
                controller: _title,
                enabled: !_saving,
                errorText: _titleError,
                maxLines: 1,
              ),
              const SizedBox(height: 12),
              AetherField(
                label: 'Task',
                fieldKey: const ValueKey('schedule-prompt'),
                controller: _description,
                enabled: !_saving,
                errorText: _descriptionError,
                // Keep the primary action reachable on compact viewports.
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              Text(context.l10n.scheduleRecurrence, style: AetherType.label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in [
                    (value: 'at', label: 'One-off'),
                    (value: 'daily_at', label: 'Daily'),
                    (value: 'every_seconds', label: 'Interval'),
                    if (widget.schedule.trigger.kind == 'cron')
                      (value: 'cron', label: context.l10n.scheduleCron),
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
                  label: Text(context.l10n.scheduleAdvanced),
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
                      'Repeats in the stored time zone. Follows that zone\'s DST.',
                    'every_seconds' =>
                      'Fixed interval; minimum 300 seconds (5 minutes).',
                    'cron' => 'Five fields; the server validates the expression.',
                    _ =>
                      'Device-local time unless you include Z or an offset, e.g. +05:30. Past times are due immediately.',
                  },
                ),
                const SizedBox(height: 8),
              ],
              Text(context.l10n.schedulePreview, style: AetherType.label),
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
                      color: Aether.danger,
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
            ? 'Runs daily at $value (${_tz ?? 'device time zone'}).'
            : 'Runs daily at ${l10n.formatTimeOfDay(t)} '
                '(${_tz ?? 'device time zone'}).';
      case 'every_seconds':
        final seconds = int.tryParse(value);
        if (seconds == null) {
          return 'Runs every $value seconds after the next save.';
        }
        return 'Runs every ${describeScheduleInterval(seconds)} after the next save.';
      case 'cron':
        return "Runs on cron '$value' (${_tz ?? 'device time zone'}).";
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

/// Shortest allowed interval (the server's `every` floor).
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

/// Local `YYYY-MM-DD HH:mm` (the parser reads a value without Z or an offset
/// as device-local time).
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
      ScheduleClient.parseDate(stored.trim()).toLocal(),
    );
  } on FormatException {
    return stored;
  }
}

/// A card representing a single server-backed scheduled task.
class _TaskCard extends StatefulWidget {
  final ScheduleDto schedule;
  final Future<void> Function() onChanged;
  final VoidCallback onEdit;

  const _TaskCard({
    super.key,
    required this.schedule,
    required this.onChanged,
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
    final s = widget.schedule;
    final status = s.status;
    final next = s.nextRunAt?.toLocal();
    final title = s.title.trim().isEmpty ? s.description : s.title;
    final last = s.lastResult;

    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    AetherPill(
                      label: status,
                      color: _statusColor(status),
                      filled: status != 'completed' && status != 'cancelled',
                    ),
                    if (last?.ranLate == true)
                      AetherPill(
                        key: const ValueKey('schedule-ran-late'),
                        label: context.l10n.scheduleRanLate,
                        color: Aether.warn,
                      ),
                    if (s.pausedReason == 'missed_beyond_grace')
                      AetherPill(
                        key: const ValueKey('schedule-missed-run'),
                        label: context.l10n.scheduleMissedRun,
                        color: Aether.warn,
                      ),
                  ],
                ),
              ),
              _menu(context, s),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title.isEmpty ? '(empty)' : title,
            style: AetherType.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Text(_prettyRecurrence(s.trigger), style: AetherType.bodyMuted),
          if (last != null) ...[
            const SizedBox(height: 6),
            Text(
              _lastResultLine(last),
              style: AetherType.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (status == 'failed' || status == 'paused') ...[
            const SizedBox(height: 8),
            Text(
              status == 'failed' ? 'Recovery needed' : _pausedLabel(s),
              style: TextStyle(
                color: _statusColor(status),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (last?.message != null && last!.message!.isNotEmpty)
              Text(last.message!, style: AetherType.caption),
          ],
          const SizedBox(height: 4),
          Text(_secondary(status, next, last), style: AetherType.bodyMuted),
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
            _details(s),
          ],
        ],
      ),
    );
  }

  Widget _menu(BuildContext context, ScheduleDto s) {
    final status = s.status;
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'edit',
        enabled: !s.isTerminal,
        child: Text('Edit', style: AetherType.body),
      ),
      if (status == 'pending')
        PopupMenuItem<String>(
          value: 'pause',
          child: Text('Pause', style: AetherType.body),
        ),
      if (status == 'paused')
        PopupMenuItem<String>(
          value: 'resume',
          child: Text('Resume', style: AetherType.body),
        ),
      if (status != 'cancelled')
        PopupMenuItem<String>(
          value: 'cancel',
          child: Text(
            context.l10n.scheduleCancelTask,
            style: AetherType.body.copyWith(color: Aether.danger),
          ),
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
            _runAction(() async {
              await ScheduleClient.I.update(s.id, status: 'paused');
            });
          case 'resume':
            _runAction(() async {
              await ScheduleClient.I.update(s.id, status: 'pending');
            });
          case 'cancel':
            _confirmCancel(context, s);
        }
      },
    );
  }

  /// Cancelling is irreversible (and stops future runs), so it confirms.
  Future<void> _confirmCancel(BuildContext context, ScheduleDto s) async {
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.scheduleCancelTaskTitle,
      message: s.status == 'pending'
          ? l.scheduleCancelTaskRunningMessage
          : l.scheduleCancelTaskMessage,
      confirmLabel: l.scheduleCancelTask,
      cancelLabel: l.scheduleKeepTask,
    );
    if (!ok || !mounted) return;
    await _runAction(() => ScheduleClient.I.delete(s.id));
  }

  Future<void> _runAction(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
      await widget.onChanged();
      if (mounted) setState(() => _feedback = context.l10n.scheduleUpdated);
    } catch (e, st) {
      if (mounted) {
        final l = context.l10n;
        final failure = scheduleFailure(l, e, st, 'schedule_screen.task');
        setState(() => _feedback = l.scheduleUpdateFailed(failure));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _details(ScheduleDto s) {
    final next = s.nextRunAt?.toLocal();
    final last = s.lastResult;
    final finished = last?.finishedAt?.toLocal();
    final scheduledLabel = next != null ? _fmtInstant(next) : 'Not scheduled';
    final nextRunLabel = s.status == 'pending' && next != null
        ? _nextRunLabel(next)
        : _executionLabel(s.status);
    final tz = s.trigger.tz;
    final zoneLabel = tz != null
        ? '$tz · server-scheduled'
        : next == null
        ? 'Unavailable'
        : '${_zoneLabel(next)} · device-local display';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.scheduleDescription, style: AetherType.label),
        const SizedBox(height: 4),
        Text(
          s.description.isEmpty ? '(empty)' : s.description,
          style: AetherType.body,
        ),
        const SizedBox(height: 10),
        _detailRow('Scheduled', scheduledLabel),
        _detailRow('Time zone', zoneLabel),
        _detailRow('Recurrence', _prettyRecurrence(s.trigger)),
        _detailRow('Next run', nextRunLabel),
        _detailRow(
          'Last run',
          last == null
              ? 'Never run'
              : '${last.status}'
                  '${finished == null ? '' : ' · ${_fmtInstant(finished)}'}'
                  '${last.ranLate ? ' · ran late' : ''}',
        ),
        _detailRow(
          'Retries',
          'Up to ${s.maxRetries} · pre-execution failures only',
        ),
        if (last?.message != null && last!.message!.isNotEmpty)
          _detailRow(
            last.status == 'failed' ? 'Last error' : 'Last result',
            last.message!,
          ),
        const SizedBox(height: 8),
        Text(context.l10n.scheduleRawSpec, style: AetherType.label),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Aether.codeBg,
            borderRadius: BorderRadius.circular(AetherRadius.rSm),
            border: Border.all(color: Aether.hairline),
          ),
          child: Text(_rawSpec(s.trigger), style: AetherType.mono),
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
          if (constraints.maxWidth < 520 ||
              MediaQuery.textScalerOf(context).scale(14) > 20) {
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
          '· ${_fmtInstant(next)}';
    }
    return 'In ${_fmtDuration(diff)} · ${_fmtInstant(next)}';
  }

  String _secondary(String status, DateTime? next, ScheduleLastResult? last) {
    if (status == 'pending' && next != null) {
      final now = DateTime.now();
      final diff = next.difference(now);
      if (diff.isNegative) {
        return 'Overdue by ${_fmtDuration(diff.abs())} · ${_fmtInstant(next)}';
      }
      return 'Next in ${_fmtDuration(diff)} · ${_fmtInstant(next)}';
    }
    return '${_executionLabel(status)}'
        '${last != null ? ' · Last run: ${last.status}' : ''}';
  }

  String _pausedLabel(ScheduleDto s) => switch (s.pausedReason) {
    'missed_beyond_grace' => 'Missed while Ovid was offline · review and resume',
    'retries_exhausted' => 'Retries exhausted · review and resume',
    _ => 'Paused · resume to run',
  };

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

String _lastResultLine(ScheduleLastResult last) {
  final message = (last.message ?? '').trim();
  final when = last.finishedAt == null
      ? ''
      : ' · ${_fmtInstant(last.finishedAt!.toLocal())}';
  final late = last.ranLate ? ' · ran late' : '';
  return message.isEmpty
      ? 'Last run: ${last.status}$late$when'
      : 'Last run: ${last.status}$late · $message';
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

String _rawSpec(ScheduleTrigger trigger) => switch (trigger.kind) {
  'at' => 'at=${trigger.at?.toUtc().toIso8601String() ?? '—'}',
  'every' => 'every=${trigger.seconds}s',
  'daily_at' => 'daily_at=${trigger.time} tz=${trigger.tz}',
  'cron' => 'cron=${trigger.expr} tz=${trigger.tz}',
  _ => 'spec=unknown',
};

String _prettyRecurrence(ScheduleTrigger trigger) => switch (trigger.kind) {
  'at' => trigger.at == null
      ? 'One-off · unknown'
      : 'One-off · ${_fmtInstant(trigger.at!.toLocal())}',
  'every' => 'Every ${_fmtInterval(trigger.seconds ?? 0)} · fixed interval',
  'daily_at' =>
    'Daily · ${trigger.time ?? '—'} · ${trigger.tz ?? 'unknown zone'}',
  'cron' => "Cron · '${trigger.expr ?? '—'}' · ${trigger.tz ?? 'unknown zone'}",
  _ => 'Unknown trigger',
};

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
