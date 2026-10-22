/// Shared display formatters.
library;

import 'package:intl/intl.dart';

/// User-visible words and unit suffixes used by the formatters below.
///
/// `intl` localizes month names, day periods and date order, but it has no
/// relative-time formatter. Those words live here so a translation pass can
/// supply a translated instance instead of editing every call site:
///
/// ```dart
/// formatTimeUntil(deadline, strings: const MyFormatStrings());
/// ```
///
/// The defaults are English and keep the current copy unchanged.
class FormatStrings {
  const FormatStrings({
    this.now = 'now',
    this.underAMinute = 'in under a minute',
    this.dueNow = 'due now',
    this.resettingNow = 'Resetting now',
    this.resets = 'Resets',
    this.inPrefix = 'in',
    this.dateTimeSeparator = ', ',
    this.second = 's',
    this.minute = 'm',
    this.hour = 'h',
    this.day = 'd',
  });

  final String now;
  final String underAMinute;
  final String dueNow;
  final String resettingNow;
  final String resets;

  /// Leading word for relative time (`in 5 h`, `dans 5 h`).
  final String inPrefix;

  /// Between a localized date and a localized time, e.g. `Oct 20` + `, ` +
  /// `11:30 AM`.
  final String dateTimeSeparator;

  final String second;
  final String minute;
  final String hour;
  final String day;

  /// Relative-time phrases: `in 2 d 3 h`, `in 5 h 12 m`, `in 12 m`.
  String inDays(int days) => '$inPrefix $days $day';
  String inDaysHours(int days, int hours) =>
      '$inPrefix $days $day $hours $hour';
  String inHours(int hours) => '$inPrefix $hours $hour';
  String inHoursMinutes(int hours, int minutes) =>
      '$inPrefix $hours $hour $minutes $minute';
  String inMinutes(int minutes) => '$inPrefix $minutes $minute';

  /// Compact durations: `9m 27s`, `2h 5m`.
  String seconds(int seconds) => '$seconds$second';
  String minutes(int minutes) => '$minutes$minute';
  String minutesSeconds(int minutes, int seconds) =>
      '$minutes$minute $seconds$second';
  String hours(int hours) => '$hours$hour';
  String hoursMinutes(int hours, int minutes) =>
      '$hours$hour $minutes$minute';
}

/// Compact count for token/usage/time-style numbers: `999`, `1K`, `1.5K`,
/// `2.5M`, `2.5B`. One decimal place, trailing `.0` trimmed. Mirrors the
/// reference UI's compact stat style without its identifiers.
String formatCompactCount(num value) {
  final neg = value < 0;
  final n = value.abs().toDouble();
  String out;
  if (n < 1000) {
    out = n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toString();
  } else if (n < 1000000) {
    out = '${_trim(n / 1000)}K';
  } else if (n < 1000000000) {
    out = '${_trim(n / 1000000)}M';
  } else {
    out = '${_trim(n / 1000000000)}B';
  }
  return neg ? '-$out' : out;
}

String _trim(double v) {
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// Boundary-aware truncation that never strands a half-cut character or a
/// dangling ellipsis inside a word. Returns text no longer than [max].
String cleanTruncate(String text, int max) {
  if (text.length <= max) return text;
  final cut = text.substring(0, max);
  // Avoid cutting inside a surrogate pair.
  final safe = cut.codeUnits.last >= 0xD800 && cut.codeUnits.last <= 0xDBFF
      ? cut.substring(0, cut.length - 1)
      : cut;
  return '$safe…';
}

/// Compact human-readable duration: `0.4s`, `12s`, `9m 27s`, `2h 5m`.
/// Never emits unreadable raw seconds like `567s`.
String formatCompactDuration(
  Duration d, {
  FormatStrings strings = const FormatStrings(),
}) {
  final ms = d.inMilliseconds;
  if (ms < 1000) {
    final s = (ms / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}'
        '${strings.second}';
  }
  final totalSec = d.inSeconds;
  if (totalSec < 60) {
    return strings.seconds(totalSec);
  }
  final totalMin = d.inMinutes;
  final remSec = totalSec % 60;
  if (totalMin < 60) {
    return remSec > 0
        ? strings.minutesSeconds(totalMin, remSec)
        : strings.minutes(totalMin);
  }
  final totalHours = d.inHours;
  final remMin = totalMin % 60;
  return remMin > 0
      ? strings.hoursMinutes(totalHours, remMin)
      : strings.hours(totalHours);
}

/// Local wall-clock date and time: `Oct 20, 11:30 AM` (the year is added
/// when it differs from [now]'s). Never a raw ISO string (SH-016, SH-022).
///
/// Month names, date order and AM/PM come from `intl` for [locale]
/// (default: the current `intl` locale). Relative words are in [strings].
String formatLocalDateTime(
  DateTime value, {
  DateTime? now,
  String? locale,
  FormatStrings strings = const FormatStrings(),
}) {
  final t = value.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final date = _formatDate(t, ref, locale);
  final time = _formatTime(t, locale);
  return '$date${strings.dateTimeSeparator}$time';
}

/// Local calendar day: `Oct 20` (with the year when not [now]'s year).
String formatLocalDay(
  DateTime value, {
  DateTime? now,
  String? locale,
  FormatStrings strings = const FormatStrings(),
}) {
  final t = value.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  return _formatDate(t, ref, locale);
}

/// Coarse time until [value]: `in 5 h 12 m`, `in 12 m`, `in 2 d 3 h`,
/// `in under a minute`; `now` once it has passed.
String formatTimeUntil(
  DateTime value, {
  DateTime? now,
  FormatStrings strings = const FormatStrings(),
}) {
  final left = value.toUtc().difference((now ?? DateTime.now()).toUtc());
  if (left.inSeconds <= 0) return strings.now;
  if (left.inMinutes < 1) return strings.underAMinute;
  final days = left.inDays;
  final hours = left.inHours % 24;
  final minutes = left.inMinutes % 60;
  if (days > 0) {
    return hours > 0 ? strings.inDaysHours(days, hours) : strings.inDays(days);
  }
  if (left.inHours > 0) {
    return minutes > 0
        ? strings.inHoursMinutes(left.inHours, minutes)
        : strings.inHours(left.inHours);
  }
  return strings.inMinutes(minutes);
}

/// `Resets in 5 h 12 m · Oct 19, 1:45 PM` for an allowance window.
String formatResetLabel(
  DateTime resetsAt, {
  DateTime? now,
  String? locale,
  FormatStrings strings = const FormatStrings(),
}) {
  final until = formatTimeUntil(resetsAt, now: now, strings: strings);
  final at = formatLocalDateTime(
    resetsAt,
    now: now,
    locale: locale,
    strings: strings,
  );
  return until == strings.now
      ? strings.resettingNow
      : '${strings.resets} $until · $at';
}

/// A deadline with its countdown: `Oct 20, 11:30 AM (in 23 h)`.
String formatDeadline(
  DateTime deadline, {
  DateTime? now,
  String? locale,
  FormatStrings strings = const FormatStrings(),
}) {
  final until = formatTimeUntil(deadline, now: now, strings: strings);
  final at = formatLocalDateTime(
    deadline,
    now: now,
    locale: locale,
    strings: strings,
  );
  return until == strings.now ? '$at (${strings.dueNow})' : '$at ($until)';
}

String _formatDate(DateTime t, DateTime ref, String? locale) {
  final l = locale ?? Intl.getCurrentLocale();
  final date = t.year == ref.year
      ? DateFormat.MMMd(l).format(t)
      : DateFormat.yMMMd(l).format(t);
  return _cleanSpaces(date);
}

String _formatTime(DateTime t, String? locale) {
  final l = locale ?? Intl.getCurrentLocale();
  return _cleanSpaces(DateFormat.jm(l).format(t));
}

/// `intl` emits U+202F before AM/PM in several locales. Normalize it (and
/// U+00A0) to a regular space so formatted strings match the rest of the UI.
String _cleanSpaces(String value) =>
    value.replaceAll('\u202F', ' ').replaceAll('\u00A0', ' ');
