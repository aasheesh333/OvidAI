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
