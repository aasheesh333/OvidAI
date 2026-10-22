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
    this.timezoneId = 'Asia/Kolkata',
  });

  final V2CadenceFrequency frequency;

  /// Local run time, 24-hour clock.
  final int hour;
  final int minute;

  /// 1 = Monday … 7 = Sunday. Only used by [V2CadenceFrequency.weekly].
  final Set<int> days;

  /// A cron expression (`0 9 * * 1-5`) or an RRULE
  /// (`FREQ=WEEKLY;BYDAY=MO;BYHOUR=9`) for [V2CadenceFrequency.custom].
  final String customRule;
  final String timezoneLabel;
  final String timezoneShort;

  /// The IANA zone the trigger is saved with, e.g. `Asia/Kolkata`.
  final String timezoneId;

  /// e.g. "9:00 AM".
  String get timeLabel => formatCadenceTime(hour, minute);

  /// The first thing the user must fix, or null when the cadence is complete.
  String? get validationError {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return 'Pick a run time between 12:00 AM and 11:59 PM.';
    }
    if (frequency == V2CadenceFrequency.weekly) {
      if (days.isEmpty) return 'Pick at least one day for this to run.';
      if (days.any((day) => day < 1 || day > 7)) {
        return 'Days must be between Monday and Sunday.';
      }
    }
    if (frequency == V2CadenceFrequency.custom) {
      final rule = customRule.trim();
      if (rule.isEmpty) return 'Describe when this should run.';
      if (rule.length < 3) return 'Add a little more detail to the rule.';
      if (!_looksLikeScheduleExpression(rule) && rule.length > 120) {
        return 'Keep the rule under 120 characters.';
      }
      if (!_looksLikeScheduleExpression(rule)) {
        return 'Use a cron expression or RRULE, for example 0 9 * * 1-5.';
      }
      if (rule.length > 200) return 'Keep the rule under 200 characters.';
      final cron = normalizedCustomExpression(rule);
      final rrule = normalizedCustomRrule(rule);
      if (cron == null && rrule == null) {
        return 'That is not a valid cron or RRULE. Check the fields.';
      }
      if (cron == null && rruleToCron(rrule!) == null) {
        return 'This RRULE cannot be saved yet. Use a cron expression or a '
            'daily/weekly rule.';
      }
    }
    return null;
  }

  bool get isValid => validationError == null;

  /// The cron expression this cadence saves (`0 9 * * 1,2,3,4,5`), or an empty
  /// string for a custom rule that is not a cron expression.
  String get cronExpression => switch (frequency) {
    V2CadenceFrequency.daily => '$minute $hour * * *',
    V2CadenceFrequency.weekly => '$minute $hour * * ${_sortedDays.join(',')}',
    V2CadenceFrequency.custom => normalizedCustomExpression(customRule) ?? '',
  };

  List<int> get _sortedDays {
    final sorted = days.where((day) => day >= 1 && day <= 7).toList()..sort();
    return sorted;
  }

  /// The RRULE this cadence saves, or an empty string when the custom rule is a
  /// cron expression rather than an RRULE.
  String get rrule => switch (frequency) {
    V2CadenceFrequency.daily => 'FREQ=DAILY;BYHOUR=$hour;BYMINUTE=$minute',
    V2CadenceFrequency.weekly =>
      'FREQ=WEEKLY;BYDAY=${_sortedDays.map(rruleDayCode).join(',')};'
          'BYHOUR=$hour;BYMINUTE=$minute',
    V2CadenceFrequency.custom => normalizedCustomRrule(customRule) ?? '',
  };

  /// What the editor sends to the server: a cron expression or an RRULE.
  String get scheduleExpression {
    final custom = frequency == V2CadenceFrequency.custom;
    if (!custom) return 'cron $cronExpression';
    final rrule = normalizedCustomRrule(customRule);
    if (rrule != null) return 'RRULE:$rrule';
    final cron = normalizedCustomExpression(customRule);
    return cron == null ? '' : 'cron $cron';
  }

  /// The next local date-time this cadence fires after [from], or null when the
  /// cadence is incomplete or cannot be expanded locally.
  DateTime? nextRunAfter(DateTime from) {
    if (!isValid) return null;
    final rule = _rule;
    if (rule == null) return null;

    // 400 days covers a weekly rule with any interval up to a year plus the
    // day-of-week offset; it is a hard bound, never an infinite loop.
    for (var offset = 0; offset <= 400; offset++) {
      final candidate = DateTime(
        from.year,
        from.month,
        from.day + offset,
        rule.hour,
        rule.minute,
      );
      if (candidate.isAfter(from) && rule.matches(candidate)) return candidate;
    }
    return null;
  }

  _CadenceRule? get _rule {
    switch (frequency) {
      case V2CadenceFrequency.daily:
        return _CadenceRule(
          hour: hour,
          minute: minute,
          interval: 1,
          days: const <int>{},
        );
      case V2CadenceFrequency.weekly:
        return _CadenceRule(
          hour: hour,
          minute: minute,
          interval: 1,
          days: days.where((day) => day >= 1 && day <= 7).toSet(),
        );
      case V2CadenceFrequency.custom:
        return _customRuleSchedule(customRule);
    }
  }

  V2CadenceDraft copyWith({
    V2CadenceFrequency? frequency,
    int? hour,
    int? minute,
    Set<int>? days,
    String? customRule,
    String? timezoneLabel,
    String? timezoneShort,
    String? timezoneId,
  }) {
    return V2CadenceDraft(
      frequency: frequency ?? this.frequency,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      days: days == null ? this.days : Set<int>.unmodifiable(days),
      customRule: customRule ?? this.customRule,
      timezoneLabel: timezoneLabel ?? this.timezoneLabel,
      timezoneShort: timezoneShort ?? this.timezoneShort,
      timezoneId: timezoneId ?? this.timezoneId,
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
        other.timezoneShort == timezoneShort &&
        other.timezoneId == timezoneId;
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
      timezoneId,
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

// ── Cron / RRULE ────────────────────────────────────────────────────────────
//
// A cadence is only real when it can be sent as a trigger the scheduler
// understands. The structured options always produce a five-field cron
// expression; a custom rule must be a cron expression or an RRULE, and both
// are validated here instead of at the server.

const _cronFieldBounds = <(int, int)>[
  (0, 59), // minute
  (0, 23), // hour
  (1, 31), // day of month
  (1, 12), // month
  (0, 7), // day of week (0 and 7 are Sunday)
];

/// True when [expression] is a five-field cron expression in range.
bool isValidCron(String expression) => _parseCron(expression) != null;

Set<int>? _cronFieldValues(String token, int min, int max) {
  if (token.isEmpty) return null;
  final values = <int>{};
  for (final raw in token.split(',')) {
    if (raw.isEmpty) return null;
    var body = raw;
    var step = 1;
    final slash = body.indexOf('/');
    if (slash >= 0) {
      step = int.tryParse(body.substring(slash + 1)) ?? 0;
      if (step < 1) return null;
      body = body.substring(0, slash);
    }
    var start = min;
    var end = max;
    if (body != '*') {
      final dash = body.indexOf('-');
      if (dash > 0) {
        start = int.tryParse(body.substring(0, dash)) ?? (1 << 30);
        end = int.tryParse(body.substring(dash + 1)) ?? -(1 << 30);
      } else {
        start = int.tryParse(body) ?? (1 << 30);
        end = start;
      }
    }
    if (start < min || end > max || start > end) return null;
    for (var value = start; value <= end; value += step) {
      values.add(value);
    }
  }
  return values.isEmpty ? null : values;
}

class _CronSpec {
  const _CronSpec({
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  final Set<int> minutes;
  final Set<int> hours;
  final Set<int> daysOfMonth;
  final Set<int> months;
  final Set<int> daysOfWeek;
}

_CronSpec? _parseCron(String expression) {
  final text = expression.trim();
  if (text.isEmpty) return null;
  final parts = text.split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final fields = <Set<int>>[];
  for (var index = 0; index < 5; index++) {
    final bounds = _cronFieldBounds[index];
    final values = _cronFieldValues(parts[index], bounds.$1, bounds.$2);
    if (values == null) return null;
    fields.add(values);
  }
  return _CronSpec(
    minutes: fields[0],
    hours: fields[1],
    daysOfMonth: fields[2],
    months: fields[3],
    daysOfWeek: fields[4],
  );
}

const _rruleKeys = <String>{
  'FREQ',
  'INTERVAL',
  'COUNT',
  'UNTIL',
  'BYDAY',
  'BYMONTHDAY',
  'BYMONTH',
  'BYHOUR',
  'BYMINUTE',
  'BYSECOND',
  'WKST',
  'BYSETPOS',
  'BYWEEKNO',
  'BYYEARDAY',
};

const _rruleFrequencies = <String>{
  'SECONDLY',
  'MINUTELY',
  'HOURLY',
  'DAILY',
  'WEEKLY',
  'MONTHLY',
  'YEARLY',
};

const _rruleDayCodes = <String>['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// The RRULE weekday code for 1 = Monday … 7 = Sunday.
String rruleDayCode(int day) =>
    day >= 1 && day <= 7 ? _rruleDayCodes[day - 1] : '';

bool _rruleDay(String value) =>
    RegExp(r'^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$').hasMatch(value);

bool _intListInRange(String value, int min, int max) {
  for (final part in value.split(',')) {
    final parsed = int.tryParse(part);
    if (parsed == null || parsed < min || parsed > max) return false;
  }
  return true;
}

Map<String, String>? _parseRrule(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (text.toUpperCase().startsWith('RRULE:')) text = text.substring(6);
  final fields = <String, String>{};
  for (final part in text.split(';')) {
    final equals = part.indexOf('=');
    if (equals <= 0) return null;
    final key = part.substring(0, equals).trim().toUpperCase();
    final value = part.substring(equals + 1).trim();
    if (value.isEmpty || !_rruleKeys.contains(key)) return null;
    if (fields.containsKey(key)) return null;
    fields[key] = value;
  }
  final frequency = fields['FREQ']?.toUpperCase();
  if (frequency == null || !_rruleFrequencies.contains(frequency)) return null;
  fields['FREQ'] = frequency;

  final interval = fields['INTERVAL'];
  if (interval != null) {
    final parsed = int.tryParse(interval);
    if (parsed == null || parsed < 1 || parsed > 99) return null;
  }
  final count = fields['COUNT'];
  if (count != null) {
    final parsed = int.tryParse(count);
    if (parsed == null || parsed < 1) return null;
  }
  final until = fields['UNTIL'];
  if (until != null) {
    final compact = RegExp(r'^\d{8}$').hasMatch(until);
    if (!compact && DateTime.tryParse(until) == null) return null;
  }
  final byHour = fields['BYHOUR'];
  if (byHour != null && !_intListInRange(byHour, 0, 23)) return null;
  final byMinute = fields['BYMINUTE'];
  if (byMinute != null && !_intListInRange(byMinute, 0, 59)) return null;
  final bySecond = fields['BYSECOND'];
  if (bySecond != null && !_intListInRange(bySecond, 0, 59)) return null;
  final byMonth = fields['BYMONTH'];
  if (byMonth != null && !_intListInRange(byMonth, 1, 12)) return null;
  final byMonthDay = fields['BYMONTHDAY'];
  if (byMonthDay != null) {
    for (final part in byMonthDay.split(',')) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed == 0 || parsed < -31 || parsed > 31) {
        return null;
      }
    }
  }
  final byDay = fields['BYDAY'];
  if (byDay != null) {
    for (final part in byDay.split(',')) {
      if (!_rruleDay(part.toUpperCase())) return null;
    }
    fields['BYDAY'] = byDay.toUpperCase();
  }
  final weekStart = fields['WKST'];
  if (weekStart != null && !_rruleDayCodes.contains(weekStart.toUpperCase())) {
    return null;
  }
  final bySetPos = fields['BYSETPOS'];
  if (bySetPos != null) {
    for (final part in bySetPos.split(',')) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed == 0 || parsed < -366 || parsed > 366) {
        return null;
      }
    }
  }
  return fields;
}

/// The canonical RRULE for [input] (`FREQ=...`), or null when it is not one.
String? normalizedCustomRrule(String input) {
  final fields = _parseRrule(input);
  if (fields == null) return null;
  const order = <String>[
    'FREQ',
    'INTERVAL',
    'BYDAY',
    'BYMONTHDAY',
    'BYMONTH',
    'BYHOUR',
    'BYMINUTE',
    'BYSECOND',
    'COUNT',
    'UNTIL',
    'WKST',
    'BYSETPOS',
    'BYWEEKNO',
    'BYYEARDAY',
  ];
  final out = <String>[];
  for (final key in order) {
    final value = fields[key];
    if (value != null) out.add('$key=$value');
  }
  return out.isEmpty ? null : out.join(';');
}

/// The trimmed cron expression for [input], or null when it is not a cron.
String? normalizedCustomExpression(String input) {
  final text = input.trim();
  if (_parseCron(text) == null) return null;
  return text.split(RegExp(r'\s+')).join(' ');
}

bool _looksLikeScheduleExpression(String rule) {
  final upper = rule.toUpperCase();
  if (upper.startsWith('RRULE:') || upper.contains('FREQ=')) return true;
  final cronLike = RegExp(r'^[\d*/,\- ]+$').hasMatch(rule);
  return cronLike && rule.split(RegExp(r'\s+')).length == 5;
}

/// The cron expression for [rrule] when the two can express the same schedule,
/// or null (cron cannot carry an interval or a monthly position).
String? rruleToCron(String rrule) {
  final fields = _parseRrule(rrule);
  if (fields == null) return null;
  final hour = _singleInt(fields['BYHOUR']);
  final minute = _singleInt(fields['BYMINUTE']) ?? 0;
  final interval = int.tryParse(fields['INTERVAL'] ?? '1') ?? 1;
  if (hour == null || interval != 1) return null;
  if (fields['FREQ'] == 'DAILY') return '$minute $hour * * *';
  if (fields['FREQ'] == 'WEEKLY') {
    final days = _rruleDays(fields['BYDAY']);
    if (days == null || days.isEmpty) return null;
    final sorted = days.toList()..sort();
    return '$minute $hour * * ${sorted.join(',')}';
  }
  return null;
}

/// Rebuilds the cadence a saved cron expression represents. Every valid cron
/// becomes a draft: the simple shapes become the Daily/Weekly segments, the
/// rest stay custom so the expression is visible and editable.
V2CadenceDraft? cadenceFromCron(
  String expression, {
  String timezoneId = 'UTC',
  String? timezoneLabel,
  String? timezoneShort,
}) {
  final text = expression.trim();
  final cron = _parseCron(text);
  if (cron == null) return null;
  final zone = timezoneId.isEmpty ? 'UTC' : timezoneId;
  final label = timezoneLabel ?? zone;
  final short = timezoneShort ?? _shortZone(zone);
  if (cron.minutes.length == 1 &&
      cron.hours.length == 1 &&
      cron.months.length == 12) {
    final hour = cron.hours.single;
    final minute = cron.minutes.single;
    if (cron.daysOfMonth.length == 31) {
      if (cron.daysOfWeek.length == 8) {
        return V2CadenceDraft(
          frequency: V2CadenceFrequency.daily,
          hour: hour,
          minute: minute,
          timezoneId: zone,
          timezoneLabel: label,
          timezoneShort: short,
        );
      }
      return V2CadenceDraft(
        frequency: V2CadenceFrequency.weekly,
        hour: hour,
        minute: minute,
        days: cron.daysOfWeek.map((day) => day == 0 ? 7 : day).toSet(),
        timezoneId: zone,
        timezoneLabel: label,
        timezoneShort: short,
      );
    }
  }
  return V2CadenceDraft(
    frequency: V2CadenceFrequency.custom,
    customRule: text.split(RegExp(r'\s+')).join(' '),
    timezoneId: zone,
    timezoneLabel: label,
    timezoneShort: short,
  );
}

/// Rebuilds the cadence a saved RRULE represents, or null when it is invalid.
V2CadenceDraft? cadenceFromRrule(
  String rrule, {
  String timezoneId = 'UTC',
  String? timezoneLabel,
  String? timezoneShort,
}) {
  final normalized = normalizedCustomRrule(rrule);
  if (normalized == null) return null;
  final fields = _parseRrule(normalized)!;
  final zone = timezoneId.isEmpty ? 'UTC' : timezoneId;
  final label = timezoneLabel ?? zone;
  final short = timezoneShort ?? _shortZone(zone);
  final hour = _singleInt(fields['BYHOUR']);
  final minute = _singleInt(fields['BYMINUTE']) ?? 0;
  final interval = int.tryParse(fields['INTERVAL'] ?? '1') ?? 1;
  if (hour != null && interval == 1) {
    if (fields['FREQ'] == 'DAILY') {
      return V2CadenceDraft(
        frequency: V2CadenceFrequency.daily,
        hour: hour,
        minute: minute,
        timezoneId: zone,
        timezoneLabel: label,
        timezoneShort: short,
      );
    }
    if (fields['FREQ'] == 'WEEKLY') {
      final days = _rruleDays(fields['BYDAY']);
      if (days != null && days.isNotEmpty) {
        return V2CadenceDraft(
          frequency: V2CadenceFrequency.weekly,
          hour: hour,
          minute: minute,
          days: days,
          timezoneId: zone,
          timezoneLabel: label,
          timezoneShort: short,
        );
      }
    }
  }
  return V2CadenceDraft(
    frequency: V2CadenceFrequency.custom,
    customRule: normalized,
    timezoneId: zone,
    timezoneLabel: label,
    timezoneShort: short,
  );
}

String _shortZone(String zone) {
  final slash = zone.lastIndexOf('/');
  return slash < 0 ? zone : zone.substring(slash + 1);
}

int? _singleInt(String? value) {
  if (value == null) return null;
  final parts = value.split(',');
  if (parts.length != 1) return null;
  return int.tryParse(parts.single);
}

Set<int>? _rruleDays(String? value) {
  if (value == null || value.isEmpty) return null;
  final days = <int>{};
  for (final part in value.toUpperCase().split(',')) {
    final code = part.length <= 2 ? part : part.substring(part.length - 2);
    final index = _rruleDayCodes.indexOf(code);
    if (index < 0) return null;
    days.add(index + 1);
  }
  return days;
}

/// The expandable shape of a cadence, used for the next-run preview.
@immutable
class _CadenceRule {
  const _CadenceRule({
    required this.hour,
    required this.minute,
    required this.interval,
    required this.days,
  });

  final int hour;
  final int minute;
  final int interval;

  /// 1 = Monday … 7 = Sunday. Empty means "every day".
  final Set<int> days;

  static final DateTime _dailyAnchor = DateTime.utc(1970, 1, 1);
  static final DateTime _weeklyAnchor = DateTime.utc(1970, 1, 5); // Monday.

  bool get isDaily => days.isEmpty;

  bool matches(DateTime value) {
    final day = DateTime.utc(value.year, value.month, value.day);
    if (isDaily) {
      return day.difference(_dailyAnchor).inDays % interval == 0;
    }
    if (!days.contains(day.weekday)) return false;
    final weeks = day.difference(_weeklyAnchor).inDays ~/ 7;
    return weeks % interval == 0;
  }
}

_CadenceRule? _customRuleSchedule(String rule) {
  final fields = _parseRrule(rule);
  if (fields != null) {
    final frequency = fields['FREQ'];
    final interval = int.tryParse(fields['INTERVAL'] ?? '1') ?? 1;
    final hour = _singleInt(fields['BYHOUR']);
    final minute = _singleInt(fields['BYMINUTE']) ?? 0;
    if (hour == null) return null;
    if (frequency == 'DAILY') {
      return _CadenceRule(
        hour: hour,
        minute: minute,
        interval: interval,
        days: const <int>{},
      );
    }
    if (frequency == 'WEEKLY') {
      final days = _rruleDays(fields['BYDAY']);
      if (days == null || days.isEmpty) return null;
      return _CadenceRule(
        hour: hour,
        minute: minute,
        interval: interval,
        days: days,
      );
    }
    return null;
  }

  final cron = _parseCron(rule);
  if (cron == null) return null;
  if (cron.minutes.length != 1 || cron.hours.length != 1) return null;
  if (cron.months.length != 12) return null;
  final hour = cron.hours.single;
  final minute = cron.minutes.single;
  final everyDayOfMonth = cron.daysOfMonth.length == 31;
  final everyDayOfWeek = cron.daysOfWeek.length == 8;
  if (everyDayOfMonth && everyDayOfWeek) {
    return _CadenceRule(
      hour: hour,
      minute: minute,
      interval: 1,
      days: const <int>{},
    );
  }
  if (everyDayOfMonth && !everyDayOfWeek) {
    return _CadenceRule(
      hour: hour,
      minute: minute,
      interval: 1,
      days: cron.daysOfWeek.map((day) => day == 0 ? 7 : day).toSet(),
    );
  }
  return null;
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
/// "Saturday, 24 Oct at 9:00 AM". Null when there is no predictable next run
/// (for example a cron rule with several hours in one field).
String? describeNextRun(V2CadenceDraft draft, DateTime now) {
  if (!draft.isValid) return null;
  final next = draft.nextRunAfter(now);
  if (next == null) return null;
  return describeNextRunAt(next, now);
}

/// The same plain-English label for a concrete date-time, e.g. a server-supplied
/// `nextRunAt`.
String describeNextRunAt(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(local.year, local.month, local.day);
  final dayOffset = target.difference(today).inDays;
  final label = formatCadenceTime(local.hour, local.minute);
  if (dayOffset == 0) return 'Today at $label';
  if (dayOffset == 1) return 'Tomorrow at $label';
  final month = _monthShort[local.month - 1];
  return '${cadenceDayName(local.weekday)}, ${local.day} $month at $label';
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

/// Daily / weekly / custom cadence control with a time row, weekday chips and
/// inline validation.
///
/// Host it inside a schedule editor (or any scrollable form) and pass every
/// change up through [onChanged]. When [onTimeTap] is set the host owns that
/// picker; otherwise the time row opens the standard Material time picker.
class CadencePicker extends StatefulWidget {
  const CadencePicker({
    super.key,
    required this.draft,
    required this.now,
    this.onChanged,
    this.onTimeTap,
    this.enabled = true,
  });

  final V2CadenceDraft draft;

  /// "Now" for the next-run preview. Injected so the preview is deterministic.
  final DateTime now;
  final ValueChanged<V2CadenceDraft>? onChanged;

  /// Host-owned time picker. When null the picker opens its own dialog.
  final VoidCallback? onTimeTap;

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
                    child: Text(
                      'Run time',
                      style: OType.bodySm.copyWith(
                        color: enabled ? c.text : c.textFaint,
                        fontWeight: FontWeight.w600,
                      ),
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
          if (error != null) ...[
            const SizedBox(height: OSpace.m),
            _errorLine(c, error),
          ],
        ],
      ),
    );
  }

  String _daysHeadline() {
    if (_draft.days.isEmpty) return 'Pick at least one day';
    if (_isWeekdays(_draft.days)) return 'Runs Mon – Fri';
    if (_isWeekend(_draft.days)) return 'Runs Sat – Sun';
    if (_draft.days.length == 7) return 'Runs every day';
    if (_draft.days.length == 1) return 'Runs 1 day a week';
    return 'Runs ${_draft.days.length} days a week';
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
                hintText: '0 9 * * 1-5',
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
              child: Icon(
                Icons.error_outline_rounded,
                size: 15,
                color: c.danger,
              ),
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
