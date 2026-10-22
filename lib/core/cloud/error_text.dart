/// Pure string checks for failure copy.
///
/// Deliberately free of `dart:io` and Flutter: the web preview builds the
/// schedules screen, so the screen cannot import the full error table (which
/// needs `SocketException` and friends). Both layers share these rules.
library;

/// One line of server prose, or null when the text is a provider dump, stack
/// trace, HTTP status or identifier that must never reach a screen. Callers
/// that only have a free-text failure (a scheduled run's `error`) use this
/// instead of printing the raw string.
String? cloudErrorDetail(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  final firstLine = text.split('\n').first.trim();
  if (!isHumanFailureText(firstLine)) return null;
  return firstLine.length <= 240
      ? firstLine
      : '${firstLine.substring(0, 237)}…';
}

/// True for short server prose; false for provider exception dumps, stack
/// traces, JSON blobs, identifiers and request-validation internals.
bool isHumanFailureText(String text) {
  if (text.length > 240) return false;
  if (text.contains('\n    at ') || text.contains('Traceback')) return false;
  if (text.contains('Error:') ||
      text.contains('Exception') ||
      text.contains('DioError') ||
      text.contains('SocketException') ||
      text.contains('ClientException') ||
      text.contains('HandshakeException') ||
      text.contains('Null check') ||
      text.contains('status code') ||
      text.contains('HTTP 4') ||
      text.contains('HTTP 5') ||
      text.contains('litellm') ||
      text.startsWith('Invalid request body') ||
      text.startsWith('{') ||
      text.startsWith('[')) {
    return false;
  }
  if (RegExp(r'^[a-z0-9_]+$').hasMatch(text)) return false;
  return true;
}
