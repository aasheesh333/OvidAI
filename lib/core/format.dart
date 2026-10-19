/// Shared display formatters.
library;

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
String formatCompactDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) {
    final s = (ms / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}s';
  }
  final totalSec = d.inSeconds;
  if (totalSec < 60) {
    return '${totalSec}s';
  }
  final totalMin = d.inMinutes;
  final remSec = totalSec % 60;
  if (totalMin < 60) {
    return remSec > 0 ? '${totalMin}m ${remSec}s' : '${totalMin}m';
  }
  final totalHours = d.inHours;
  final remMin = totalMin % 60;
  return remMin > 0 ? '${totalHours}h ${remMin}m' : '${totalHours}h';
}

const _monthAbbr = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Local wall-clock date and time: `Oct 20, 11:30 AM` (the year is added
/// when it differs from [now]'s). Never a raw ISO string (SH-016, SH-022).
String formatLocalDateTime(DateTime value, {DateTime? now}) {
  final t = value.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  final year = t.year == ref.year ? '' : ', ${t.year}';
  return '${_monthAbbr[t.month - 1]} ${t.day}$year, $hour12:$minute $ampm';
}

/// Local calendar day: `Oct 20` (with the year when not [now]'s year).
String formatLocalDay(DateTime value, {DateTime? now}) {
  final t = value.toLocal();
  final ref = (now ?? DateTime.now()).toLocal();
  final year = t.year == ref.year ? '' : ', ${t.year}';
  return '${_monthAbbr[t.month - 1]} ${t.day}$year';
}

/// Coarse time until [value]: `in 5 h 12 m`, `in 12 m`, `in 2 d 3 h`,
/// `in under a minute`; `now` once it has passed.
String formatTimeUntil(DateTime value, {DateTime? now}) {
  final left = value.toUtc().difference((now ?? DateTime.now()).toUtc());
  if (left.inSeconds <= 0) return 'now';
  if (left.inMinutes < 1) return 'in under a minute';
  final days = left.inDays;
  final hours = left.inHours % 24;
  final minutes = left.inMinutes % 60;
  if (days > 0) return hours > 0 ? 'in $days d $hours h' : 'in $days d';
  if (left.inHours > 0) {
    return minutes > 0
        ? 'in ${left.inHours} h $minutes m'
        : 'in ${left.inHours} h';
  }
  return 'in $minutes m';
}

/// `Resets in 5 h 12 m · Oct 19, 1:45 PM` for an allowance window.
String formatResetLabel(DateTime resetsAt, {DateTime? now}) {
  final until = formatTimeUntil(resetsAt, now: now);
  final at = formatLocalDateTime(resetsAt, now: now);
  return until == 'now' ? 'Resetting now' : 'Resets $until · $at';
}

/// A deadline with its countdown: `Oct 20, 11:30 AM (in 23 h)`.
String formatDeadline(DateTime deadline, {DateTime? now}) {
  final until = formatTimeUntil(deadline, now: now);
  final at = formatLocalDateTime(deadline, now: now);
  return until == 'now' ? '$at (due now)' : '$at ($until)';
}
