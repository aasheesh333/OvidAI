import 'package:flutter/foundation.dart';

import 'secret_scrub.dart';

/// One entry in the diagnostics ring buffer.
class DiagEntry {
  DiagEntry(this.context, this.error, this.stack, this.at);
  final String context;
  final String error;
  final StackTrace? stack;
  final DateTime at;
}

/// Central sink for otherwise-swallowed errors.
///
/// Replaces bare `catch (_) {}` blocks: behaviour stays fail-closed (the error
/// is still not rethrown), but it becomes observable — a bounded ring buffer
/// the health screen and tests can read, plus a debug log line. This closes the
/// "hundreds of silent catches" finding without changing control flow.
class Diag {
  Diag._();

  static const int _max = 200;
  static final List<DiagEntry> _ring = <DiagEntry>[];

  /// Test/diagnostic hook: called for every swallow. A throwing hook is
  /// itself swallowed so the seam can never re-enter or crash a catch block.
  static void Function(DiagEntry entry)? onSwallow;

  /// Record a swallowed error. [context] is a short, stable tag such as
  /// `'mcp_service.disconnect'` so callers can be grouped and searched.
  ///
  /// The error text is scrubbed (M4) before it is stored or printed:
  /// exceptions routinely embed the request URL (`ClientException …,
  /// uri=https://host/?token=…`) or a command line, and the ring buffer
  /// feeds the health screen and diagnostic exports.
  static void swallow(String context, Object error, [StackTrace? stack]) {
    final text = scrubSecretsInText('$error');
    final entry = DiagEntry(context, text, stack, DateTime.now());
    _ring.add(entry);
    if (_ring.length > _max) {
      _ring.removeRange(0, _ring.length - _max);
    }
    if (kDebugMode) debugPrint('[diag] $context: $text');
    try {
      onSwallow?.call(entry);
    } catch (_) {
      // A misbehaving hook must never re-enter or crash the swallow path.
    }
  }

  /// Newest-last snapshot of the ring buffer.
  static List<DiagEntry> recent() => List.unmodifiable(_ring);

  @visibleForTesting
  static void resetForTest() {
    _ring.clear();
    onSwallow = null;
  }
}
