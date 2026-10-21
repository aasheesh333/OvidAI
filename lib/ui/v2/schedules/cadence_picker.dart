import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this picker to the ARB files.

/// How often a schedule runs.
enum V2CadenceFrequency { daily, weekly, custom }

/// The cadence the user is editing. Immutable: every change is reported through
/// [CadencePicker.onChanged] so the wiring layer stays the source of truth.
@immutable
class V2CadenceDraft {
  const V2CadenceDraft({
    this.frequency = V2CadenceFrequency.weekly,
    this.hour = 9,
    this.minute = 0,
    this.days = const <int>{1, 2, 3, 4, 5},
    this.customRule = '',
    this.timezoneLabel = 'Asia/Kolkata (GMT +5:30)',
    this.timezoneShort = 'IST',
  });

  final V2CadenceFrequency frequency;

  /// Local run time, 24-hour clock.
  final int hour;
  final int minute;

  /// 1 = Monday … 7 = Sunday. Only used by [V2CadenceFrequency.weekly].
  final Set<int> days;

  /// Plain-language rule for [V2CadenceFrequency.custom].
  final String customRule;
  final String timezoneLabel;
  final String timezoneShort;

  /// e.g. "9:00 AM".
  String get timeLabel => formatCadenceTime(hour, minute);

  /// The first thing the user must fix, or null when the cadence is complete.
  String? get validationError {
    if (frequency == V2CadenceFrequency.weekly && days.isEmpty) {
      return 'Pick at least one day for this to run.';
    }
    if (frequency == V2CadenceFrequency.custom) {
      final rule = customRule.trim();
      if (rule.isEmpty) return 'Describe when this should run.';
      if (rule.length < 3) return 'Add a little more detail to the rule.';
      if (rule.length > 120) return 'Keep the rule under 120 characters.';
    }
    return null;
  }

  bool get isValid => validationError == null;

  /// The next local date-time this cadence fires after [from], or null when the
  /// cadence is incomplete or custom (the server owns custom rules).
  DateTime? nextRunAfter(DateTime from) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    if (frequency == V2CadenceFrequency.custom) return null;

    final activeDays = days.where((day) => day >= 1 && day <= 7).toSet();
    if (frequency == V2CadenceFrequency.weekly && activeDays.isEmpty) {
      return null;
    }

    // Eight candidates cover every weekday once, including today.
    for (var offset = 0; offset <= 7; offset++) {
      final candidate = DateTime(
        from.year,
        from.month,
        from.day + offset,
        hour,
        minute,
      );
      final matches = frequency == V2CadenceFrequency.daily ||
          activeDays.contains(candidate.weekday);
      if (matches && candidate.isAfter(from)) return candidate;
    }
    return null;
  }

  V2CadenceDraft copyWith({
    V2CadenceFrequency? frequency,
    int? hour,
    int? minute,
    Set<int>? days,
    String? customRule,
    String? timezoneLabel,
    String? timezoneShort,
  }) {
    return V2CadenceDraft(
      frequency: frequency ?? this.frequency,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      days: days == null ? this.days : Set<int>.unmodifiable(days),
      customRule: customRule ?? this.customRule,
      timezoneLabel: timezoneLabel ?? this.timezoneLabel,
      timezoneShort: timezoneShort ?? this.timezoneShort,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is V2CadenceDraft &&
        other.frequency == frequency &&
        other.hour == hour &&
        other.minute == minute &&
        _sameDays(other.days, days) &&
        other.customRule == customRule &&
        other.timezoneLabel == timezoneLabel &&
        other.timezoneShort == timezoneShort;
  }

  @override
  int get hashCode {
    final sortedDays = days.toList()..sort();
    return Object.hash(
      frequency,
      hour,
      minute,
      Object.hashAll(sortedDays),
      customRule,
      timezoneLabel,
      timezoneShort,
    );
  }
}

/// "9:00 AM", "12:05 PM". Locale-free on purpose: the ARB pass owns wording.
String formatCadenceTime(int hour, int minute) {
  final safeHour = hour.clamp(0, 23);
  final safeMinute = minute.clamp(0, 59);
  final suffix = safeHour < 12 ? 'AM' : 'PM';
  final displayHour = safeHour % 12 == 0 ? 12 : safeHour % 12;
  final displayMinute = safeMinute.toString().padLeft(2, '0');
  return '$displayHour:$displayMinute $suffix';
}

/// 1 = Monday … 7 = Sunday.
String cadenceDayName(int day) => switch (day) {
  1 => 'Monday',
  2 => 'Tuesday',
  3 => 'Wednesday',
  4 => 'Thursday',
  5 => 'Friday',
  6 => 'Saturday',
  7 => 'Sunday',
  _ => 'Day $day',
};

/// One plain-English sentence for schedule cards: "Every weekday at 9:00 AM".
String describeCadence(V2CadenceDraft draft) {
  final time = draft.timeLabel;
  return switch (draft.frequency) {
    V2CadenceFrequency.daily => 'Every day at $time',
    V2CadenceFrequency.custom =>
      draft.customRule.trim().isEmpty
          ? 'Custom schedule'
          : 'Custom: ${draft.customRule.trim()}',
    V2CadenceFrequency.weekly => _describeDays(draft.days, time),
  };
}

/// The next run in plain English: "Today at 9:00 AM", "Tomorrow at 9:00 AM",
/// "Saturday, 24 Oct at 9:00 AM". Null when there is no predictable next run.
String? describeNextRun(V2CadenceDraft draft, DateTime now) {
  if (!draft.isValid) return null;
  final next = draft.nextRunAfter(now);
  if (next == null) return null;

  final today = DateTime.utc(now.year, now.month, now.day);
  final target = DateTime.utc(next.year, next.month, next.day);
  final dayOffset = target.difference(today).inDays;
  final time = draft.timeLabel;
  if (dayOffset == 0) return 'Today at $time';
  if (dayOffset == 1) return 'Tomorrow at $time';
  final month = _monthShort[next.month - 1];
  return '${cadenceDayName(next.weekday)}, ${next.day} $month at $time';
}

const _monthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

bool _sameDays(Set<int> a, Set<int> b) =>
    identical(a, b) || (a.length == b.length && a.containsAll(b));

bool _isWeekdays(Set<int> days) =>
    days.length == 5 &&
    days.contains(1) &&
    days.contains(2) &&
    days.contains(3) &&
    days.contains(4) &&
    days.contains(5);

bool _isWeekend(Set<int> days) =>
    days.length == 2 && days.contains(6) && days.contains(7);

String _describeDays(Set<int> days, String time) {
  if (days.isEmpty) return 'No days picked yet';
  if (_isWeekdays(days)) return 'Every weekday at $time';
  if (_isWeekend(days)) return 'Every weekend at $time';
  if (days.length == 7) return 'Every day at $time';
  if (days.length == 1) {
    return 'Every ${cadenceDayName(days.first)} at $time';
  }
  return 'Every ${_joinDayNames(days)} at $time';
}

String _joinDayNames(Set<int> days) {
  final labels = (days.toList()..sort()).map(cadenceDayName).toList();
  if (labels.length == 1) return labels.first;
  if (labels.length == 2) return '${labels[0]} and ${labels[1]}';
  return '${labels.sublist(0, labels.length - 1).join(', ')} and ${labels.last}';
}

String _dayInitial(int day) {
  final name = cadenceDayName(day);
  return name.substring(0, 1);
}

String _frequencyLabel(V2CadenceFrequency frequency) => switch (frequency) {
  V2CadenceFrequency.daily => 'Daily',
  V2CadenceFrequency.weekly => 'Weekly',
  V2CadenceFrequency.custom => 'Custom',
};

/// Daily / weekly / custom cadence control with a time row, weekday chips, a
/// timezone note, a plain-English next-run preview and inline validation.
///
/// Host it inside a schedule editor (or any scrollable form) and pass every
/// change up through [onChanged]. When [onTimeTap] or
/// [onTimezoneTap] is set the host owns that picker; otherwise the time row
/// opens the standard Material time picker itself.
class CadencePicker extends StatefulWidget {
  const CadencePicker({
    super.key,
    required this.draft,
    required this.now,
    this.onChanged,
    this.onTimeTap,
    this.onTimezoneTap,
    this.enabled = true,
  });

  final V2CadenceDraft draft;

  /// "Now" for the next-run preview. Injected so the preview is deterministic.
  final DateTime now;
  final ValueChanged<V2CadenceDraft>? onChanged;

  /// Host-owned time picker. When null the picker opens its own dialog.
  final VoidCallback? onTimeTap;
  final VoidCallback? onTimezoneTap;

  /// False announces the whole control as read only and blocks every change.
  final bool enabled;

  @override
  State<CadencePicker> createState() => _CadencePickerState();
}

class _CadencePickerState extends State<CadencePicker> {
  late V2CadenceDraft _draft;
  late final TextEditingController _rule;

  @override
  void initState() {
    super.initState();
    _draft = widget.draft;
    _rule = TextEditingController(text: widget.draft.customRule);
  }

  @override
  void didUpdateWidget(covariant CadencePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.draft != oldWidget.draft) {
      _draft = widget.draft;
      final rule = widget.draft.customRule;
      if (_rule.text != rule) {
        // The parent may reset the draft while building; sync the field after
        // the frame so the controller does not notify mid-build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _rule.text == rule) return;
          _rule.value = TextEditingValue(
            text: rule,
            selection: TextSelection.collapsed(offset: rule.length),
          );
        });
      }
    }
  }

  @override
  void dispose() {
    _rule.dispose();
    super.dispose();
  }

  void _update(V2CadenceDraft next) {
    setState(() => _draft = next);
    widget.onChanged?.call(next);
  }

  void _setFrequency(V2CadenceFrequency frequency) {
    if (!widget.enabled) return;
    if (frequency == _draft.frequency) return;
    _update(_draft.copyWith(frequency: frequency));
  }

  void _toggleDay(int day) {
    if (!widget.enabled) return;
    final days = <int>{..._draft.days};
    if (!days.remove(day)) days.add(day);
    _update(_draft.copyWith(days: days));
  }

  void _setRule(String value) {
    if (!widget.enabled) return;
    _update(_draft.copyWith(customRule: value));
  }

  void _applyRule(String value) {
    if (!widget.enabled) return;
    _rule.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _setRule(value);
  }

  Future<void> _pickTime() async {
    if (!widget.enabled) return;
    final external = widget.onTimeTap;
    if (external != null) {
      external();
      return;
    }

    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _draft.hour, minute: _draft.minute),
      helpText: 'Run time',
      builder: (dialogContext, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (!mounted || picked == null) return;
    _update(_draft.copyWith(hour: picked.hour, minute: picked.minute));
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final draft = _draft;
    final error = draft.validationError;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _frequencyControl(c),
        const SizedBox(height: OSpace.m),
        _timeRow(c),
        if (draft.frequency == V2CadenceFrequency.weekly) ...[
          const SizedBox(height: OSpace.m),
          _daysCard(c),
        ],
        if (draft.frequency == V2CadenceFrequency.custom) ...[
          const SizedBox(height: OSpace.m),
          _customCard(c),
        ],
        const SizedBox(height: OSpace.m),
        _timezoneCard(c),
        const SizedBox(height: OSpace.m),
        _preview(c, error),
        if (!widget.enabled) ...[
          const SizedBox(height: OSpace.s),
          Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 15, color: c.textFaint),
              const SizedBox(width: OSpace.xs),
              Expanded(
                child: Text(
                  'Cadence is read only.',
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _frequencyControl(OColors c) {
    // At 150% text and above three segments cannot share one 320 dp row
    // without truncating, so they stack into full-width rows instead.
    final scaledLabel = MediaQuery.textScalerOf(context).scale(14);
    final stacked = scaledLabel > 20;
    final buttons = <Widget>[
      for (final frequency in V2CadenceFrequency.values)
        _frequencyButton(c, frequency),
    ];
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(height: OSpace.xs),
                  buttons[i],
                ],
              ],
            )
          : Row(
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(width: OSpace.xs),
                  Expanded(child: buttons[i]),
                ],
              ],
            ),
    );
  }

  Widget _frequencyButton(OColors c, V2CadenceFrequency frequency) {
    final selected = _draft.frequency == frequency;
    final enabled = widget.enabled;
    final foreground = selected
        ? (enabled ? c.onAccent : c.textMuted)
        : (enabled ? c.textMuted : c.textFaint);
    return MergeSemantics(
      child: Semantics(
        label: _frequencyLabel(frequency),
        button: true,
        selected: selected,
        enabled: enabled,
        child: OPressable(
          onTap: enabled ? () => _setFrequency(frequency) : null,
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
            decoration: BoxDecoration(
              color: selected
                  ? (enabled ? c.accentFill : c.surfaceRaised)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(ORadius.s),
            ),
            child: ExcludeSemantics(
              child: Text(
                _frequencyLabel(frequency),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: OType.label.copyWith(color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _timeRow(OColors c) {
    final enabled = widget.enabled;
    final label = enabled
        ? 'Run time, ${_draft.timeLabel}. Change.'
        : 'Run time, ${_draft.timeLabel}. Read only.';
    return Semantics(
      label: label,
      button: enabled,
      enabled: enabled,
      onTap: enabled ? _pickTime : null,
      child: ExcludeSemantics(
        child: OCard(
          onTap: enabled ? _pickTime : null,
          padding: const EdgeInsets.all(OSpace.m),
          child: Wrap(
            spacing: OSpace.m,
            runSpacing: OSpace.s,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _rowIcon(c, Icons.schedule_rounded),
                  const SizedBox(width: OSpace.m),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Run time',
                          style: OType.bodySm.copyWith(
                            color: enabled ? c.text : c.textFaint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'When it starts',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.m,
                  vertical: OSpace.s,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.s),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _draft.timeLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: enabled ? c.text : c.textFaint,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: OSpace.xs),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: enabled ? c.textMuted : c.textFaint,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _daysCard(OColors c) {
    final error = _draft.frequency == V2CadenceFrequency.weekly
        ? _draft.validationError
        : null;
    final valid = error == null;
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  'REPEAT DAYS',
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
              ),
              Icon(
                Icons.event_repeat_rounded,
                size: 14,
                color: valid ? c.success : c.warn,
              ),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  _daysHeadline(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: valid ? c.success : c.warn,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              for (final day in const [1, 2, 3, 4, 5, 6, 7]) _dayChip(c, day),
            ],
          ),
          const SizedBox(height: OSpace.m),
          if (error != null)
            _errorLine(c, error)
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: OSpace.xs),
                Expanded(
                  child: Text(
                    _daysSummary(),
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _daysHeadline() {
    if (_draft.days.isEmpty) return 'Pick at least one day';
    if (_isWeekdays(_draft.days)) return 'Runs Mon – Fri';
    if (_isWeekend(_draft.days)) return 'Runs Sat – Sun';
    if (_draft.days.length == 7) return 'Runs every day';
    return 'Runs ${_draft.days.length} days a week';
  }

  String _daysSummary() {
    final days = _draft.days;
    if (_isWeekdays(days)) return 'Runs on weekdays (Mon – Fri).';
    if (_isWeekend(days)) return 'Runs on weekends (Sat – Sun).';
    if (days.length == 7) return 'Runs every day of the week.';
    return 'Runs on ${_joinDayNames(days)}.';
  }

  Widget _dayChip(OColors c, int day) {
    final selected = _draft.days.contains(day);
    final enabled = widget.enabled;
    return MergeSemantics(
      key: ValueKey('cadence-day-$day'),
      child: Semantics(
        label: cadenceDayName(day),
        button: true,
        selected: selected,
        enabled: enabled,
        child: OPressable(
          onTap: enabled ? () => _toggleDay(day) : null,
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            width: OSpace.touch,
            height: OSpace.touch,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? (enabled ? c.accentFill : c.surfaceRaised)
                  : c.surfaceAlt,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? (enabled ? c.accentFill : c.hairlineStrong)
                    : c.hairline,
              ),
            ),
            child: ExcludeSemantics(
              child: Text(
                _dayInitial(day),
                style: OType.label.copyWith(
                  color: selected
                      ? (enabled ? c.onAccent : c.textMuted)
                      : (enabled ? c.textMuted : c.textFaint),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _customCard(OColors c) {
    final error = _draft.frequency == V2CadenceFrequency.custom
        ? _draft.validationError
        : null;
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CUSTOM CADENCE',
            style: OType.overline.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Say in your own words when this should run.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.s),
          Semantics(
            container: true,
            label: 'Custom cadence rule',
            child: TextField(
              key: const ValueKey('cadence-custom-rule'),
              controller: _rule,
              enabled: widget.enabled,
              minLines: 2,
              maxLines: 3,
              maxLength: 120,
              textCapitalization: TextCapitalization.sentences,
              onChanged: _setRule,
              style: OType.bodySm.copyWith(color: c.text),
              cursorColor: c.accent,
              decoration: InputDecoration(
                hintText: 'e.g. Every other Monday at 6 PM',
                hintStyle: OType.bodySm.copyWith(color: c.textFaint),
                counterText: '',
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: OSpace.s),
            _errorLine(c, error),
          ],
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              OChip(
                label: 'Every other Monday',
                onTap: widget.enabled
                    ? () => _applyRule('Every other Monday at 6 PM')
                    : null,
              ),
              OChip(
                label: '1st of the month',
                onTap: widget.enabled
                    ? () => _applyRule('The first day of each month at 8 AM')
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _timezoneCard(OColors c) {
    final tappable = widget.enabled && widget.onTimezoneTap != null;
    final label = tappable
        ? 'Timezone, ${_draft.timezoneLabel}. Change.'
        : 'Timezone, ${_draft.timezoneLabel}.';
    return Semantics(
      label: label,
      button: tappable,
      enabled: widget.enabled,
      onTap: tappable ? widget.onTimezoneTap : null,
      child: ExcludeSemantics(
        child: OCard(
          onTap: tappable ? widget.onTimezoneTap : null,
          padding: const EdgeInsets.all(OSpace.m),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _rowIcon(c, Icons.public_rounded, color: c.success),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Timezone',
                      style: OType.bodySm.copyWith(
                        color: widget.enabled ? c.text : c.textFaint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _draft.timezoneLabel,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      'Times use ${_draft.timezoneShort}. Ovid handles daylight '
                      'saving changes.',
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.xs),
              if (tappable) ...[
                Text(
                  'Change',
                  style: OType.caption.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
              ] else if (widget.onTimezoneTap != null)
                Icon(Icons.lock_outline_rounded, size: 16, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview(OColors c, String? error) {
    final draft = _draft;
    final next = error == null ? describeNextRun(draft, widget.now) : null;
    final tone = error != null ? c.warn : c.accent;
    final title = error != null
        ? 'Add the missing details'
        : next ?? 'Set by your custom rule';
    final detail = error != null
        ? 'The next run appears once the cadence is complete.'
        : next != null
            ? '${describeCadence(draft)} · ${draft.timezoneShort}'
            : draft.customRule.trim();

    return OCard(
      accent: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              error != null ? Icons.info_outline_rounded : Icons.auto_awesome_rounded,
              size: 17,
              color: tone,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NEXT RUN',
                  style: OType.overline.copyWith(color: tone),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  title,
                  style: OType.bodyStrong.copyWith(
                    color: error != null ? c.text : c.accent,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: OSpace.xs),
                  Text(
                    detail,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
                const SizedBox(height: OSpace.s),
                Text(
                  'Runs in the cloud, even when your phone is off.',
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorLine(OColors c, String message) {
    return Semantics(
      key: const ValueKey('cadence-error'),
      liveRegion: true,
      label: message,
      child: ExcludeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, size: 15, color: c.danger),
            ),
            const SizedBox(width: OSpace.xs),
            Expanded(
              child: Text(
                message,
                style: OType.caption.copyWith(color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowIcon(OColors c, IconData icon, {Color? color}) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(icon, size: 20, color: color ?? c.accent),
    );
  }
}
